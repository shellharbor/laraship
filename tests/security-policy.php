<?php
// Run in each patched PHP smoke image, never in a retired PHP runtime.
require '/usr/local/share/laraship/security-policy.php';

function expect_policy(callable $check, bool $accepted): void
{
    try {
        $check();
    } catch (Throwable $error) {
        if (!$accepted) {
            return;
        }
        throw $error;
    }
    if (!$accepted) {
        throw new RuntimeException('An unsafe or invalid version was accepted');
    }
}

foreach (['8.2.35', '8.2.36', '8.3.36', '8.3.37', '8.4.27', '8.4.28', '8.5.12', '8.5.13'] as $version) {
    expect_policy(fn() => laraship_check_php($version), true);
}
foreach (['7.4.99', '8.0.99', '8.1.99', '8.2.34', '8.3.35', '8.4.26', '8.5.11',
          '8.3', '8.3.36RC1', '8.5.12-dev', '8.6.0', '9.0.0', 'garbage'] as $version) {
    expect_policy(fn() => laraship_check_php($version), false);
}
foreach (['12.0.0', 'v12.52.0', '13.0.0'] as $version) {
    expect_policy(fn() => laraship_check_laravel($version), true);
}
foreach (['9.99.99', '10.0.0', '11.99.99', 'dev-master', '13.0.0-beta1', '12.0'] as $version) {
    expect_policy(fn() => laraship_check_laravel($version), false);
}
$path = tempnam('/tmp', 'laraship-policy-');
try {
    foreach (['v9.52.21' => false, 'v10.48.0' => false, 'v11.0.0' => false, 'v12.0.0' => true] as $version => $accepted) {
        file_put_contents($path, json_encode(['packages' => [['name' => 'laravel/framework', 'version' => $version]]]));
        expect_policy(fn() => laraship_check_lock($path), $accepted);
    }
    foreach (['{}', 'invalid json', '{"packages-dev":[{"name":"laravel/framework","version":"v12.0.0"}]}'] as $invalid) {
        file_put_contents($path, $invalid);
        expect_policy(fn() => laraship_check_lock($path), false);
    }
} finally {
    unlink($path);
}
expect_policy(fn() => laraship_check_lock($path), false);
laraship_check_php(PHP_VERSION);
echo 'PHP/Laravel security policy boundaries and locked dependency checks passed' . PHP_EOL;
