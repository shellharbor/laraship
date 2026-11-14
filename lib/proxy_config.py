#!/usr/bin/env python3
"""Adapt existing standalone shared proxies without replacing their configuration."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

MARKER = 'x-laraship-proxy'


class ConfigError(ValueError):
    pass


def nginx_tokens(text: str):
    """Yield values and source positions; quoted/comment/variable braces are data."""
    i = 0
    while i < len(text):
        if text[i].isspace():
            i += 1
            continue
        if text[i] == '#':
            i = text.find('\n', i)
            if i < 0:
                return
            continue
        start = i
        if text[i] in '{};':
            yield text[i], start, True
            i += 1
            continue
        value = ''
        while i < len(text) and not text[i].isspace() and text[i] not in '{};#':
            if text[i] in '\"\'':
                quote = text[i]
                i += 1
                while i < len(text) and text[i] != quote:
                    if text[i] == '\\' and i + 1 < len(text):
                        i += 1
                    value += text[i]
                    i += 1
                if i == len(text):
                    raise ConfigError('Unterminated quoted Nginx value')
                i += 1
            elif text.startswith('${', i):
                end = text.find('}', i + 2)
                if end < 0:
                    raise ConfigError('Unterminated Nginx variable')
                value += text[i:end + 1]
                i = end + 1
            elif text[i] == '\\' and i + 1 < len(text):
                value += text[i + 1]
                i += 2
            else:
                value += text[i]
                i += 1
        yield value, start, False


def nginx_structure(text: str):
    stack, pending, directives, http_closes = [], [], [], []
    for value, position, structural in nginx_tokens(text):
        if not structural:
            pending.append(value)
        elif value == '{':
            if not pending:
                raise ConfigError('Unexpected Nginx block')
            directives.append((tuple(stack), tuple(pending)))
            stack.append(pending[0])
            pending = []
        elif value == ';':
            directives.append((tuple(stack), tuple(pending)))
            pending = []
        else:
            if pending or not stack:
                raise ConfigError('Unbalanced Nginx configuration')
            if stack == ['http']:
                http_closes.append(position)
            stack.pop()
    if stack or pending:
        raise ConfigError('Incomplete Nginx configuration')
    return directives, http_closes


def enable_sites(text: str) -> str:
    directives, closes = nginx_structure(text)
    if len(closes) != 1:
        raise ConfigError('Expected one explicit http block in the mounted main Nginx configuration')
    for context, words in directives:
        if context == ('http',) and len(words) == 2 and words[0] == 'include':
            path = os.path.normpath('/etc/nginx/' + words[1]) if not words[1].startswith('/') else words[1]
            if path in ('/etc/nginx/sites/*.conf', '/etc/nginx/sites/*'):
                return text
    position = closes[0]
    line = text.rfind('\n', 0, position) + 1
    if not text[line:position].strip():
        position = line
    prefix = '' if position == 0 or text[position - 1] == '\n' else '\n'
    return text[:position] + prefix + '    # Additional sites managed by LaraShip.\n    include /etc/nginx/sites/*.conf;\n' + text[position:]


def check_conflicts(texts: list[str], slug: str, domain: str) -> None:
    for text in texts:
        directives, _ = nginx_structure(text)
        for _, words in directives:
            if words and words[0] == 'server_name' and domain.casefold() in [word.casefold() for word in words[1:]]:
                raise ConfigError('This hostname already belongs to another proxy site')
            if len(words) == 2 and words[0] == 'upstream' and words[1] in (slug, slug + '_https'):
                raise ConfigError('This upstream name already belongs to another proxy site')


def managed(path: Path) -> bool:
    try:
        value = json.loads(path.read_text(encoding='utf-8'))
        return value.get(MARKER) == {'schema': 1}
    except (ValueError, AttributeError):
        return False


def load_model(path: Path, project_name: str = 'nginxproxy') -> dict:
    if managed(path):
        return json.loads(path.read_text(encoding='utf-8'))
    overrides = ('docker-compose.override.yml', 'docker-compose.override.yaml', 'compose.override.yml', 'compose.override.yaml')
    if any((path.parent / name).exists() for name in overrides):
        raise ConfigError('Proxy override files require explicit consolidation before adoption; live configuration unchanged')
    command = ['docker', 'compose', '--project-name', project_name, '--project-directory', str(path.parent),
        '-f', str(path), 'config', '--format', 'json', '--no-interpolate', '--no-env-resolution', '--no-path-resolution', '--no-normalize']
    result = subprocess.run(command, capture_output=True, timeout=30)
    if result.returncode or len(result.stdout) > 8 * 1024 * 1024:
        raise ConfigError('Cannot parse the standalone proxy Compose file; use a current Compose v2 or newer')
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise ConfigError('Expected a Compose mapping')
    return value


def networks(value) -> dict:
    if value is None:
        return {'default': None}
    if isinstance(value, list):
        return {name: None for name in value}
    if not isinstance(value, dict):
        raise ConfigError('Unsupported proxy network configuration')
    return dict(value)


def mount(value) -> dict:
    if isinstance(value, dict):
        return value
    if not isinstance(value, str):
        raise ConfigError('Unsupported proxy volume entry')
    parts = value.split(':')
    if len(parts) not in (2, 3):
        raise ConfigError('Proxy volumes must declare explicit source and target paths')
    return {'type': 'bind' if parts[0].startswith(('.', '/')) else 'volume',
            'source': parts[0], 'target': parts[1], 'read_only': len(parts) == 3 and 'ro' in parts[2].split(',')}


def local_path(source: str, origin: Path) -> str:
    if '$' in source or '://' in source:
        raise ConfigError('Dynamic proxy bind/build paths require explicit paths before adoption')
    path = Path(os.path.normpath(str(origin / source)))
    try:
        return './' + path.relative_to(origin).as_posix()
    except ValueError:
        return str(path)


def prepare_paths(model: dict, origin: Path) -> None:
    """Keep internal paths staged; anchor external relative paths to the live root."""
    for service in model['services'].values():
        volumes = []
        for value in service.get('volumes', []):
            parsed = dict(mount(value))
            if parsed.get('type') == 'bind':
                parsed['source'] = local_path(parsed['source'], origin)
            if isinstance(value, str):
                parts = value.split(':')
                parts[0] = parsed['source']
                volumes.append(':'.join(parts))
            else:
                volumes.append(parsed)
        if 'volumes' in service:
            service['volumes'] = volumes
        build = service.get('build')
        if isinstance(build, str):
            service['build'] = {'context': local_path(build, origin)}
        elif isinstance(build, dict) and build.get('context'):
            build['context'] = local_path(build['context'], origin)
        if service.get('env_file'):
            value = service['env_file']
            entries = value if isinstance(value, list) else [value]
            service['env_file'] = [dict(item, path=local_path(item['path'], origin)) if isinstance(item, dict)
                                   else local_path(item, origin) for item in entries]
    for kind in ('configs', 'secrets'):
        for value in (model.get(kind) or {}).values():
            if isinstance(value, dict) and value.get('file'):
                value['file'] = local_path(value['file'], origin)


def edit_model(model: dict, slug: str, action: str) -> dict:
    service = model.get('services', {}).get('nginxproxy')
    if not isinstance(service, dict) or service.get('network_mode'):
        raise ConfigError('Expected a bridge-network nginxproxy service; network_mode proxies need a separate adapter')
    if service.get('container_name') != 'nginxproxy':
        raise ConfigError('The shared proxy service must declare container_name nginxproxy')
    references = networks(service.get('networks'))
    cert = slug + '_ssl_certificates'
    target = '/etc/letsencrypt/' + slug
    volumes = list(service.get('volumes', []))
    if action in ('register', 'enable'):
        for key, name in (('networks', slug), ('volumes', cert)):
            declarations = model.setdefault(key, {})
            if declarations is None:
                declarations = model[key] = {}
            if name in declarations and declarations[name] not in ({'external': True}, {'name': name, 'external': True}):
                raise ConfigError('A required project network or certificate volume has a conflicting definition')
            declarations[name] = {'name': name, 'external': True}
        references.setdefault(slug, None)
        for value in volumes:
            parsed = mount(value)
            if parsed['target'] == target and (parsed.get('type') != 'volume' or parsed.get('source') != cert):
                raise ConfigError('The project certificate target is already mounted from another source')
        if not any(mount(value)['target'] == target for value in volumes):
            volumes.append({'type': 'volume', 'source': cert, 'target': target})
    else:
        references.pop(slug, None)
        volumes = [value for value in volumes if not (mount(value).get('source') == cert and mount(value)['target'] == target)]
        for kind, name in (('networks', slug), ('volumes', cert)):
            other = [item for key, item in model['services'].items() if key != 'nginxproxy']
            used = any(name in networks(item.get('networks')) for item in other) if kind == 'networks' else any(
                mount(value).get('source') == name for item in other for value in item.get('volumes', []))
            if not used:
                (model.get(kind) or {}).pop(name, None)
    service['networks'], service['volumes'] = references, volumes
    model[MARKER] = {'schema': 1}
    return model


def configure(directory: Path, origin: Path, slug: str, domain: str, action: str, project_name: str = 'nginxproxy') -> bool:
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', slug) or slug.lower() == 'nginxproxy':
        raise ConfigError('Invalid project slug')
    path = directory / 'docker-compose.yml'
    adopted = not managed(path)
    model = load_model(path, project_name)
    prepare_paths(model, origin)
    service = model.get('services', {}).get('nginxproxy', {})
    if action == 'register':
        if not re.fullmatch(r'[A-Za-z0-9.-]+', domain):
            raise ConfigError('Invalid project hostname')
        main = [mount(value) for value in service.get('volumes', []) if mount(value)['target'] == '/etc/nginx/nginx.conf']
        if len(main) != 1 or main[0].get('type') != 'bind' or not main[0]['source'].startswith('./'):
            raise ConfigError('Mount the main Nginx configuration from a file inside the proxy directory')
        main_path = directory / main[0]['source']
        text = main_path.read_text(encoding='utf-8')
        others = [item.read_text(encoding='utf-8') for item in (directory / 'sites').glob('*.conf*')
                  if item.is_file() and item.name.endswith(('.conf', '.conf.disabled'))
                  and item.name not in (slug + '.conf', slug + '.conf.disabled')]
        check_conflicts([text, *others], slug, domain)
        main_path.write_text(enable_sites(text), encoding='utf-8')
        for value in service.get('volumes', []):
            parsed = mount(value)
            if parsed['target'] == '/etc/nginx/sites' and not (parsed.get('type') == 'bind' and parsed.get('source') == './sites'):
                raise ConfigError('The managed sites directory is already mounted from another source')
        if not any(mount(value)['target'] == '/etc/nginx/sites' for value in service.get('volumes', [])):
            service.setdefault('volumes', []).append({'type': 'bind', 'source': './sites', 'target': '/etc/nginx/sites', 'read_only': True})
    model = edit_model(model, slug, action)
    path.write_text(json.dumps(model, indent=2) + '\n', encoding='utf-8')
    return adopted


def check_runtime(directory: Path, project_name: str = 'nginxproxy') -> None:
    command = ['docker', 'compose', '--project-name', project_name, '--project-directory', str(directory),
               '-f', str(directory / 'docker-compose.yml'), 'config', '--format', 'json']
    result = subprocess.run(command, capture_output=True, timeout=30)
    inspected = subprocess.run(['docker', 'inspect', 'nginxproxy'], capture_output=True, timeout=15)
    if result.returncode or inspected.returncode:
        raise ConfigError('Cannot verify the existing proxy network ownership')
    model = json.loads(result.stdout)
    container = json.loads(inspected.stdout)[0]
    service = model['services']['nginxproxy']
    if service.get('container_name') != 'nginxproxy':
        raise ConfigError('The shared proxy service must declare container_name nginxproxy')
    references = networks(service.get('networks'))
    declared = {model['networks'][key]['name']: (value or {}) for key, value in references.items()}
    for name, endpoint in container.get('NetworkSettings', {}).get('Networks', {}).items():
        if name not in declared:
            raise ConfigError('Declare all existing proxy network connections in Compose before adoption')
        aliases = set(declared[name].get('aliases', [])) | {'nginxproxy', container['Id'], container['Id'][:12], container['Config'].get('Hostname')}
        if set(endpoint.get('Aliases') or []) - aliases:
            raise ConfigError('Declare existing custom proxy network aliases in Compose before adoption')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('managed', 'register', 'enable', 'disable', 'remove', 'check-runtime'))
    parser.add_argument('directory', type=Path)
    parser.add_argument('--origin', type=Path)
    parser.add_argument('--project-name', default='nginxproxy')
    parser.add_argument('--slug', default='')
    parser.add_argument('--domain', default='')
    args = parser.parse_args()
    try:
        if args.action == 'managed':
            return 0 if managed(args.directory / 'docker-compose.yml') else 1
        if args.action == 'check-runtime':
            check_runtime(args.directory, args.project_name)
            return 0
        changed = configure(args.directory, args.origin or args.directory, args.slug, args.domain, args.action, args.project_name)
        print('adopted' if changed else 'managed')
        return 0
    except ConfigError as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Compose/model diagnostics can contain interpolated credentials; omit them.
        print('Proxy configuration adaptation failed; check standalone Compose topology, mounts and hostname ownership', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
