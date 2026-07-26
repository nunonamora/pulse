# Contributing

Thanks for helping improve Pulse.

## Development setup

Requirements:

- macOS 14 or newer;
- Swift 6.0 or newer;
- Node.js 20 or newer for OpenCode integration tests;
- Ghostty 1.3+, iTerm2, or Terminal for manual focus testing.

```bash
git clone https://github.com/ixjosemi/Pulse.git
cd Pulse
swift build
swift run pulse-tests
./scripts/build-app.sh
open .build/Pulse.app
```

## Workflow

1. Open an issue for significant behavioral or architectural changes.
2. Add a failing behavioral test.
3. Implement the smallest complete change.
4. Run the full build and test commands.
5. Update documentation when behavior, permissions, privacy, or integrations change.

Use Conventional Commits, for example `fix(installer): reject symlinked config paths`. Keep pull requests focused and explain security/privacy implications.

## Pull requests

Pull requests must not contain credentials, personal session data, generated `.app` bundles, signing material, or unrelated formatting churn. By contributing, you agree that your contribution is licensed under the MIT License.
