# zig-bump

A simple, fast version bumping tool for Zig projects. Updates the version in your `build.zig.zon` file with a single command.

## Features

- 🦎 **Zig-Native** - Written in Zig, for Zig projects
- ⚡ **Fast** - Zero dependencies, compiles to native code (~231KB binary)
- 🎯 **Simple** - One command to bump your version
- 🎨 **Interactive** - Beautiful prompts show all version options
- 🌳 **Git Integration** - Auto-commit, tag, and push (like bumpx!)
- ✅ **Tested** - Comprehensive test suite
- 🔒 **Safe** - Validates versions and handles errors gracefully
- 🚀 **Production Ready** - Used to version itself

## Installation

### From Source

```bash
git clone https://github.com/stacksjs/zig-bump.git
cd zig-bump
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/bump /usr/local/bin/
```

### Verify Installation

```bash
bump --help
```

> **Note:** The binary is called `bump`, but the project is called `zig-bump`.

## Usage

### Interactive Mode

Run `bump` without arguments to get an interactive prompt:

```bash
$ bump
Current version: 1.0.0

Select version bump:

  1) patch  1.0.0 → 1.0.1
  2) minor  1.0.0 → 1.1.0
  3) major  1.0.0 → 2.0.0

Enter selection (1-3): 1
✓ Successfully bumped version from 1.0.0 to 1.0.1
```

### Basic Usage

```bash
# Bump patch version (commits, tags, pushes by default)
bump patch

# Bump minor version
bump minor

# Bump major version
bump major
```

### Git Integration (like bumpx!)

By default, `bump` will:
1. Update your `build.zig.zon` version
2. Create a git commit
3. Create a git tag (e.g., `v1.0.1`)
4. Push to remote

```bash
# Full workflow (default behavior)
bump patch                    # Updates, commits, tags, pushes

# Explicit --all flag (same as default)
bump minor --all

# Skip push (just commit and tag locally)
bump patch --no-push

# Just update the file (no git operations)
bump major --no-commit

# Preview changes without applying
bump minor --dry-run

# Custom tag name and message
bump patch --tag-name "release-1.0.1" --tag-message "Production release"
```

### Examples

```bash
# Starting with version 0.1.0
$ cat build.zig.zon
.{
    .name = "my_project",
    .version = "0.1.0",
}

# Bump patch
$ bump patch
Current version: 0.1.0
New version: 0.1.1

✓ Successfully bumped version from 0.1.0 to 0.1.1

$ cat build.zig.zon
.{
    .name = "my_project",
    .version = "0.1.1",
}
```

## How It Works

zig-bump:
1. Reads your `build.zig.zon` file
2. Finds the `.version = "X.Y.Z"` line
3. Increments the appropriate version number
4. Writes the updated content back to the file

## Command Line Options

### Release Types

| Command | Description | Example |
|---------|-------------|---------|
| `major` | Breaking changes | 1.0.0 → 2.0.0 |
| `minor` | New features | 1.0.0 → 1.1.0 |
| `patch` | Bug fixes | 1.0.0 → 1.0.1 |

### Git Options

| Flag | Description | Default |
|------|-------------|---------|
| `-a, --all` | Commit, tag, and push | true |
| `-c, --commit` | Create git commit | true |
| `--no-commit` | Skip git commit | - |
| `-t, --tag` | Create git tag | true |
| `--no-tag` | Skip git tag | - |
| `-p, --push` | Push to remote | true |
| `--no-push` | Skip push | - |
| `--sign` | Sign commits/tags with GPG | false |
| `--no-verify` | Skip git hooks | false |
| `--tag-name <name>` | Custom tag name | v{version} |
| `--tag-message <msg>` | Custom tag message | Release {tag} |

### Other Options

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview changes without applying |
| `-y, --yes` | Skip confirmation prompts |
| `-h, --help` | Show help message |

## Development

### Building

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Run directly
zig build run -- patch
```

### Testing

```bash
# Run all tests
zig build test

# Run with verbose output
zig build test --summary all
```

### Project Structure

```
zig-bump/
├── build.zig              # Build configuration
├── build.zig.zon          # Package manifest
├── src/
│   ├── main.zig           # Main CLI implementation
│   └── test_version.zig   # Unit tests
└── README.md              # This file
```

## Requirements

- Zig 0.15.0 or later
- A `build.zig.zon` file in the current directory

## Testing

The project includes comprehensive tests:

```bash
$ zig build test --summary all
Build Summary: 3/3 steps succeeded; 8/8 tests passed
```

Tests cover:
- ✅ Major version bumping
- ✅ Minor version bumping
- ✅ Patch version bumping
- ✅ Version parsing from different formats
- ✅ Error handling for invalid versions
- ✅ Error handling for invalid release types

## Examples

### Continuous Integration

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2

      - name: Install zig-bump
        run: |
          git clone https://github.com/stacksjs/zig-bump.git
          cd zig-bump && zig build -Doptimize=ReleaseFast
          sudo cp zig-out/bin/bump /usr/local/bin/

      - name: Bump version
        run: bump patch --no-push

      - name: Push changes
        run: git push --follow-tags
```

### Pre-commit Hook

```bash
# .git/hooks/pre-push
#!/bin/bash
echo "Bumping patch version..."
bump patch --no-push
```

## Roadmap

- [x] Basic version bumping (major, minor, patch)
- [x] Comprehensive test suite
- [x] Self-hosted (zig-bump can bump itself)
- [x] Git integration (auto-commit, tag, push)
- [x] Dry-run mode
- [x] Custom tag names and messages
- [x] Sign commits and tags
- [x] Skip git hooks
- [x] Interactive prompts
- [ ] Prerelease versions (alpha, beta, rc)
- [ ] Custom version formats
- [ ] Workspace support (multiple packages)
- [ ] Configuration file support

## Comparison

| Tool | Language | Size | Speed | Zig-Native |
|------|----------|------|-------|------------|
| zig-bump | Zig | ~100KB | ⚡ | ✅ |
| npm version | JavaScript | ~40MB | 🐌 | ❌ |
| cargo-bump | Rust | ~2MB | 🚀 | ❌ |

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'feat: add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT License - see LICENSE file for details

## Credits

- Built with [Zig](https://ziglang.org/)
- Inspired by [bumpx](https://github.com/stacksjs/bumpx)
- Created by the [Stacks team](https://github.com/stacksjs)

## Support

- 🐛 [Report a bug](https://github.com/stacksjs/zig-bump/issues)
- 💡 [Request a feature](https://github.com/stacksjs/zig-bump/issues)
- 📖 [Read the docs](https://github.com/stacksjs/zig-bump)

---

**Made with 🦎 by the Stacks team**
