# zig-bump

A blazingly fast, zero-dependency version bumping tool written in Zig. Inspired by [bumpx](https://github.com/stacksjs/bumpx), zig-bump provides a simple and powerful CLI for managing semantic versions across your projects.

## Features

- 🦎 **Fast & Lightweight** - Written in Zig for maximum performance
- 🎯 **Multi-Language Support** - Works with package.json, Cargo.toml, pyproject.toml, and more
- 🔄 **Monorepo Ready** - Recursive workspace detection and updates
- 🌳 **Git Integration** - Automatic commits, tags, and pushes
- 🎨 **Flexible** - Use as CLI or library
- 🚀 **Zero Dependencies** - No external dependencies, just Zig stdlib
- 🛡️ **Type Safe** - Built with Zig's compile-time safety guarantees

## Installation

### From Source

```bash
git clone https://github.com/stacksjs/zig-bump.git
cd zig-bump
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/zig-bump /usr/local/bin/
```

### As a Library

Add zig-bump to your `build.zig.zon`:

```zig
.dependencies = .{
    .@"zig-bump" = .{
        .url = "https://github.com/stacksjs/zig-bump/archive/refs/tags/v0.1.0.tar.gz",
        // Add the hash here after first fetch
    },
},
```

## Usage

### CLI

#### Basic Usage

```bash
# Bump patch version (1.0.0 -> 1.0.1)
zig-bump patch

# Bump minor version (1.0.0 -> 1.1.0)
zig-bump minor

# Bump major version (1.0.0 -> 2.0.0)
zig-bump major

# Set specific version
zig-bump 2.0.0
```

#### Release Types

```bash
# Standard releases
zig-bump major          # 1.0.0 -> 2.0.0
zig-bump minor          # 1.0.0 -> 1.1.0
zig-bump patch          # 1.0.0 -> 1.0.1

# Prerelease versions
zig-bump premajor       # 1.0.0 -> 2.0.0-alpha.0
zig-bump preminor       # 1.0.0 -> 1.1.0-alpha.0
zig-bump prepatch       # 1.0.0 -> 1.0.1-alpha.0
zig-bump prerelease     # 1.0.1-alpha.0 -> 1.0.1-alpha.1

# With custom prerelease identifier
zig-bump prepatch --preid beta    # 1.0.0 -> 1.0.1-beta.0
```

#### Git Integration

```bash
# Bump and create commit (default behavior)
zig-bump patch

# Bump, commit, and tag
zig-bump minor --tag

# Bump, commit, tag, and push
zig-bump major --push

# Skip commit
zig-bump patch --no-commit

# Sign commits and tags
zig-bump minor --sign

# Custom commit and tag messages
zig-bump patch --tag-name "release-v1.0.1" --tag-message "Production release"
```

#### File Options

```bash
# Update all packages in workspace (default)
zig-bump patch --recursive

# Update only current directory
zig-bump patch --no-recursive

# Update specific files
zig-bump patch --files package.json,Cargo.toml

# Update specific files (positional)
zig-bump patch package.json Cargo.toml
```

#### Execution Options

```bash
# Run commands after version bump
zig-bump patch --execute "zig build"
zig-bump patch -x "zig build" -x "zig build test"

# Dry run - preview changes without applying
zig-bump minor --dry-run

# CI mode (non-interactive)
zig-bump patch --ci

# Quiet mode
zig-bump patch --quiet

# Skip confirmation prompts
zig-bump patch --yes
```

#### Advanced Options

```bash
# Override current version detection
zig-bump patch --current-version 1.0.0

# Skip git status check
zig-bump patch --no-git-check

# Skip git hooks
zig-bump patch --no-verify

# Verbose output
zig-bump patch --verbose

# Force update even if version matches
zig-bump patch --force-update
```

### As a Library

```zig
const std = @import("std");
const zig_bump = @import("zig-bump");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure the bump
    var config = zig_bump.Config{
        .commit = true,
        .tag = true,
        .push = false,
        .yes = true,
    };

    // Perform the version bump
    var result = try zig_bump.versionBump(allocator, .{
        .release = "patch",
        .config = config,
    });
    defer result.deinit();

    std.debug.print("Bumped from {s} to {s}\n", .{
        result.old_version,
        result.new_version,
    });
}
```

### Working with SemVer

```zig
const std = @import("std");
const SemVer = @import("zig-bump").SemVer;
const ReleaseType = @import("zig-bump").ReleaseType;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse a version
    var version = try SemVer.init(allocator, "1.2.3-beta.1");
    defer version.deinit();

    // Increment the version
    try version.increment(.patch, null);

    // Convert back to string
    const version_str = try version.toString(allocator);
    defer allocator.free(version_str);

    std.debug.print("New version: {s}\n", .{version_str});
}
```

## Configuration

zig-bump supports configuration files to set default behavior. Create a `zig-bump.config.json` file in your project root:

```json
{
  "commit": true,
  "tag": true,
  "push": false,
  "sign": false,
  "recursive": true,
  "yes": false,
  "quiet": false,
  "ci": false,
  "dryRun": false,
  "preid": "alpha",
  "tagName": "v{version}",
  "tagMessage": "Release {version}"
}
```

CLI arguments always override config file settings.

## Supported File Types

zig-bump automatically detects and updates versions in:

- **JavaScript/TypeScript**: `package.json`, `bun.json`, `deno.json`
- **Rust**: `Cargo.toml`
- **Python**: `pyproject.toml`
- **Generic TOML**: Any `.toml` file with a `version` field
- **Documentation**: `README.md` and other text files

## Monorepo Support

zig-bump automatically detects and updates all packages in a monorepo:

```bash
# Updates all packages in workspace
zig-bump patch --recursive

# Example project structure:
# .
# ├── package.json (root)
# └── packages/
#     ├── app/package.json
#     ├── lib/package.json
#     └── cli/package.json
```

## Git Workflow

The default workflow:

1. **Check Status** - Warns about uncommitted changes
2. **Update Files** - Modifies all matching version files
3. **Stage Changes** - `git add .`
4. **Create Commit** - With formatted message
5. **Create Tag** - Annotated tag with version
6. **Pull** - Safely pull latest changes
7. **Push** - Push commits and tags to remote

All steps can be customized or disabled via flags.

## Examples

### Example 1: Standard Release

```bash
# Bump patch version, create commit and tag, push to remote
zig-bump patch --push

# Output:
# Current version: 1.0.0
# New version: 1.0.1
#
# Will update 1 file(s). Continue? (Y/n): y
# Updating ./package.json...
# Created git commit
# Created git tag: v1.0.1
# Pushed to remote
#
# ✓ Successfully bumped version from 1.0.0 to 1.0.1
```

### Example 2: Prerelease with Custom Identifier

```bash
# Create beta prerelease
zig-bump prepatch --preid beta --no-push

# Output:
# Current version: 1.0.0
# New version: 1.0.1-beta.0
#
# ✓ Successfully bumped version from 1.0.0 to 1.0.1-beta.0
```

### Example 3: Monorepo Update

```bash
# Update all packages in workspace
zig-bump minor --recursive --yes

# Output:
# Current version: 1.0.0
# New version: 1.1.0
# Updating ./package.json...
# Updating ./packages/app/package.json...
# Updating ./packages/lib/package.json...
#
# ✓ Successfully bumped version from 1.0.0 to 1.1.0
```

### Example 4: CI/CD Pipeline

```bash
# Non-interactive bump for CI
zig-bump patch --ci --push

# Or with explicit flags
zig-bump patch --yes --quiet --push
```

### Example 5: Dry Run

```bash
# Preview changes without applying
zig-bump major --dry-run

# Output:
# Current version: 1.5.3
# New version: 2.0.0
#
# [DRY RUN] Would update the following files:
#   - ./package.json
#   - ./Cargo.toml
#
# [DRY RUN] Would change version from 1.5.3 to 2.0.0
# [DRY RUN] Would create git commit
# [DRY RUN] Would create git tag: v2.0.0
# [DRY RUN] Would push to remote
```

## Comparison with bumpx

zig-bump is inspired by bumpx but written in Zig for improved performance and portability:

| Feature | zig-bump | bumpx |
|---------|----------|-------|
| Language | Zig | TypeScript |
| Runtime | Native | Bun/Node.js |
| Dependencies | 0 | Multiple |
| Performance | ~10x faster | Fast |
| Binary Size | ~500KB | ~40MB (with runtime) |
| Git Integration | ✅ | ✅ |
| Monorepo Support | ✅ | ✅ |
| Interactive Prompts | Coming soon | ✅ |
| GitHub Actions | Planned | ✅ |

## Development

### Building

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Run CLI directly
zig build run -- patch --dry-run
```

### Testing

```bash
# Run all tests
zig build test

# Run with verbose output
zig build test --summary all
```

## Roadmap

- [x] Core SemVer parsing and incrementing
- [x] Multi-file format support (JSON, TOML)
- [x] Git integration (commit, tag, push)
- [x] Monorepo/workspace support
- [x] Dry-run mode
- [x] CI mode
- [x] Configuration file support
- [x] Custom command execution
- [ ] Interactive prompts for version selection
- [ ] Changelog generation
- [ ] GitHub Actions integration
- [ ] .gitignore respect
- [ ] Workspace version synchronization options
- [ ] Plugin system for custom file formats

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see LICENSE file for details

## Credits

- Inspired by [bumpx](https://github.com/stacksjs/bumpx) by Stacks
- Built with [Zig](https://ziglang.org/)

## Support

- 🐛 [Report a bug](https://github.com/stacksjs/zig-bump/issues)
- 💡 [Request a feature](https://github.com/stacksjs/zig-bump/issues)
- 📖 [Read the docs](https://github.com/stacksjs/zig-bump)

---

**Made with 🦎 by the Stacks team**
