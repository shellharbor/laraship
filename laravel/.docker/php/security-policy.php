<?php
// Mandatory runtime floors. Keep the standalone Kubernetes Dockerfile copy in sync.
function laraship_check_php(string $version): void
{
    $minimums = ['8.2' => '8.2.35', '8.3' => '8.3.36', '8.4' => '8.4.27', '8.5' => '8.5.12'];
    if (!preg_match('/^(\d+)\.(\d+)\.(\d+)$/D', $version, $parts)) {
        throw new RuntimeException('PHP must have a stable major.minor.patch version');
    }
    $branch = $parts[1] . '.' . $parts[2];
    if (!isset($minimums[$branch]) || version_compare($version, $minimums[$branch], '<')) {
        throw new RuntimeException('PHP security policy requires 8.2.35+, 8.3.36+, 8.4.27+ or 8.5.12+ in those branches; PHP 8.1 and older and unreviewed branches are forbidden');
    }
}

function laraship_check_laravel(string $version): void
{
    // Retain the existing stronger Laravel 12 floor; never restore retired releases.
    if (!preg_match('/^v?\d+\.\d+\.\d+$/D', $version)
        || version_compare(ltrim($version, 'v'), '12.0.0', '<')) {
        throw new RuntimeException('Minimum supported Laravel version: 12.0; Laravel below 10 is forbidden and retired Laravel 10/11 remain unsupported');
    }
}

function laraship_check_lock(string $path): void
{
    if (!is_file($path) || !is_readable($path)) {
        throw new RuntimeException('A readable composer.lock is required to verify the Laravel security policy');
    }
    $lock = json_decode(file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
    foreach (($lock['packages'] ?? []) as $package) {
        if (($package['name'] ?? '') === 'laravel/framework') {
            laraship_check_laravel($package['version'] ?? '');
            return;
        }
    }
    throw new RuntimeException('composer.lock must contain a supported laravel/framework production dependency');
}

function laraship_security_main(array $arguments): void
{
    try {
        laraship_check_php(PHP_VERSION);
        if (isset($arguments[0]) && $arguments[0] !== '') {
            laraship_check_lock($arguments[0]);
        }
    } catch (Throwable $error) {
        fwrite(STDERR, 'LaraShip security policy: ' . $error->getMessage() . PHP_EOL);
        exit(1);
    }
}

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath($_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    laraship_security_main(array_slice($argv, 1));
}
