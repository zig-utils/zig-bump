# zig-bump

A simple, fast version bumping tool for Zig projects. Updates the version in your `build.zig.zon` file with a single command.

## Features

- 🦎 **Zig-Native** - Written in Zig, for Zig projects
- ⚡ **Fast** - Zero dependencies, compiles to native code
- 🎯 **Simple** - One command to bump your version
- ✅ **Tested** - Comprehensive test suite
- 🔒 **Safe** - Validates versions and handles errors gracefully

## Installation

### From Source

```bash
git clone https://github.com/stacksjs/zig-bump.git
cd zig-bump
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/zig-bump /usr/local/bin/
```

### Verify Installation

```bash
zig-bump --help
```

## Usage

### Basic Usage

```bash
# Bump patch version (1.0.0 -> 1.0.1)
zig-bump patch

# Bump minor version (1.0.0 -> 1.1.0)
zig-bump minor

# Bump major version (1.0.0 -> 2.0.0)
zig-bump major
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
$ zig-bump patch
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

## Release Types

| Command | Description | Example |
|---------|-------------|---------|
| `major` | Breaking changes | 1.0.0 → 2.0.0 |
| `minor` | New features | 1.0.0 → 1.1.0 |
| `patch` | Bug fixes | 1.0.0 → 1.0.1 |

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
│   ├── simple_main.zig    # Main CLI implementation
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
          sudo cp zig-out/bin/zig-bump /usr/local/bin/

      - name: Bump version
        run: zig-bump patch

      - name: Commit and push
        run: |
          git config user.name "GitHub Actions"
          git config user.email "actions@github.com"
          git add build.zig.zon
          git commit -m "chore: bump version"
          git push
```

### Pre-commit Hook

```bash
# .git/hooks/pre-push
#!/bin/bash
echo "Bumping patch version..."
zig-bump patch
git add build.zig.zon
git commit --amend --no-edit
```

## Roadmap

- [x] Basic version bumping (major, minor, patch)
- [x] Comprehensive test suite
- [x] Self-hosted (zig-bump can bump itself)
- [ ] Prerelease versions (alpha, beta, rc)
- [ ] Git integration (auto-commit, tag, push)
- [ ] Dry-run mode
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
