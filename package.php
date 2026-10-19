<?php
/**
 * Build the ZIP of one custom plugin or theme.
 *
 * tools/deploy.sh ships what this archive holds, and the same ZIP can be uploaded through
 * wp-admin by hand. WordPress installs a ZIP into the folder named by its top-level entry,
 * so every file is stored under "<slug>/". The archive is built only from a committed
 * tree, so it corresponds to one commit; `--allow-dirty` builds a "-dirty" archive for
 * a staging trial, never for production.
 *
 * Usage: php tools/package.php <slug> [--allow-dirty]
 *        php tools/package.php            (lists the packages)
 *        php tools/package.php --list     ("<type> <slug>" per line, for scripts)
 */
$root = dirname(__DIR__);
$args = array_slice($argv, 1);
$allow_dirty = in_array('--allow-dirty', $args, true);
$slug = current(array_filter($args, static fn(string $arg): bool => !str_starts_with($arg, '--')));

$fail = static function (string $message): never {
    fwrite(STDERR, "FAIL: $message\n");
    exit(1);
};

// The packages are the plugin and theme folders Git tracks: the site's own code. Third-party
// plugins sit beside them on disk but are ignored, so they never become packages.
exec('git -C ' . escapeshellarg($root) . ' ls-files -z -- wp-content/plugins wp-content/themes 2>/dev/null', $tracked, $status);
if ($status !== 0) {
    $fail('Not a Git checkout; cannot tell which plugins and themes are the site\'s own.');
}
$packages = [];
foreach (explode("\0", implode('', $tracked)) as $path) {
    if (preg_match('#^wp-content/(plugin|theme)s/([^/]+)/#', $path, $match)) {
        $packages[$match[2]] = ['type' => $match[1], 'dir' => "$root/wp-content/{$match[1]}s/{$match[2]}"];
    }
}
ksort($packages);

if (in_array('--list', $args, true)) {
    foreach ($packages as $name => $package) {
        echo "{$package['type']} $name\n";
    }
    exit(0);
}

if ($slug === false) {
    echo "Usage: php tools/package.php <slug> [--allow-dirty]\n\nPackages:\n";
    foreach ($packages as $name => $package) {
        echo "  $name ({$package['type']})\n";
    }
    exit(0);
}
if (!isset($packages[$slug])) {
    $fail("Unknown package \"$slug\". Run without arguments to list them.");
}
['type' => $type, 'dir' => $dir] = $packages[$slug];

// A package with its own release tool keeps its own checks and file list.
if (is_file("$dir/tools/package.php")) {
    echo "$slug has its own release tool; running it.\n";
    $command = escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg("$dir/tools/package.php");
    passthru($command . ($allow_dirty ? ' --allow-dirty' : ''), $code);
    exit($code);
}

// The version names the ZIP and is what wp-admin shows when it offers the replacement.
$header_file = $type === 'theme' ? "$dir/style.css" : null;
if ($type === 'plugin') {
    foreach (glob("$dir/*.php") as $file) {
        if (preg_match('/^[ \t\/*#@]*Plugin Name:/mi', (string)file_get_contents($file, false, null, 0, 8192))) {
            $header_file = $file;
            break;
        }
    }
}
if ($header_file === null || !is_file($header_file)) {
    $fail("No $type header file found in $slug.");
}
// [ \t]*, not \s*: an empty "Version:" must fail instead of taking the next line's first word.
if (!preg_match('/^[ \t\/*#@]*Version:[ \t]*(\S+)/mi', (string)file_get_contents($header_file), $match)) {
    $fail('No Version: line in ' . basename($header_file) . '.');
}
$version = $match[1];

// Committed state only, so the archive matches one commit.
$git = 'git -C ' . escapeshellarg($root);
exec("$git status --porcelain -- " . escapeshellarg($dir) . ' 2>/dev/null', $changes, $status);
if ($status !== 0) {
    $fail('Not a Git checkout; cannot confirm the package is committed.');
}
if ($changes && !$allow_dirty) {
    $fail("Uncommitted changes in $slug. Commit them, or pass --allow-dirty for a staging trial:\n" . implode("\n", $changes));
}

// build/ is ignored by Git, so it is rebuilt here from the sources being packaged.
$manifest = is_file("$dir/package.json") ? json_decode((string)file_get_contents("$dir/package.json"), true) : null;
$has_build = isset($manifest['scripts']['build']);
if ($has_build) {
    echo "Building $slug...\n";
    passthru('cd ' . escapeshellarg($dir) . ' && npm run build', $code);
    if ($code !== 0) {
        $fail('npm run build failed; no ZIP was built.');
    }
    if (!is_dir("$dir/build")) {
        $fail('The build produced no build/ folder.');
    }
}

// Tracked files (plus new ones not yet ignored, for a trial build) and the build output.
exec("$git ls-files -z --cached --others --exclude-standard -- " . escapeshellarg($dir), $listing);
$prefix = substr($dir, strlen($root) + 1) . '/';
$files = [];
foreach (explode("\0", implode('', $listing)) as $path) {
    if ($path !== '' && is_file("$root/$path")) {
        $files[] = substr($path, strlen($prefix));
    }
}
if ($has_build) {
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator("$dir/build", FilesystemIterator::SKIP_DOTS));
    foreach ($iterator as $file) {
        $files[] = substr($file->getPathname(), strlen($dir) + 1);
    }
}

// Developer files stay behind. With a build step, src/ and assets/js|scss are the webpack sources.
$excluded = static function (string $file) use ($has_build): bool {
    foreach (explode('/', $file) as $segment) {
        if ($segment === 'node_modules' || str_starts_with($segment, '.')) {
            return true;
        }
    }
    if (in_array($file, ['package.json', 'package-lock.json', 'webpack.config.js', 'README.md'], true)) {
        return true;
    }
    return $has_build && preg_match('#^(src|assets/js|assets/scss)/#', $file) === 1;
};
$files = array_values(array_unique(array_filter($files, static fn(string $file): bool => !$excluded($file))));
sort($files);
if (!$files) {
    $fail('Nothing to package.');
}

$dist = "$root/dist";
if (!is_dir($dist) && !mkdir($dist, 0755, true)) {
    $fail('Cannot create the dist directory.');
}
$path = "$dist/$slug-$version" . ($changes ? '-dirty' : '') . '.zip';
$replaced = is_file($path);
$zip = new ZipArchive();
if ($zip->open($path, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) {
    $fail('Cannot create the ZIP.');
}
foreach ($files as $file) {
    if (!$zip->addFile("$dir/$file", "$slug/$file")) {
        $fail("Could not add $file to the ZIP.");
    }
}
$zip->close();

printf("Built %s (%d files, %.1f KB)\n", substr($path, strlen($root) + 1), count($files), filesize($path) / 1024);
if ($replaced) {
    echo "NOTE: a ZIP of version $version already existed and was overwritten. Bump Version: if this is a new release.\n";
}
if ($changes) {
    echo "Trial archive from uncommitted changes: do not upload it to production.\n";
}
if ($type === 'theme') {
    echo "Upload: Appearance > Themes > Add New Theme > Upload Theme, then \"Replace active with uploaded\".\n";
    echo "Templates edited in the Site Editor live in the database and are not changed by this ZIP.\n";
} else {
    echo "Upload: Plugins > Add New Plugin > Upload Plugin, then \"Replace current with uploaded\".\n";
}
