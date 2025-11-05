# nok-tools

## Description
tools for troubleshooting

## Usage

### Fetch the package
`kpt pkg get REPO_URI[.git]/PKG_PATH[@VERSION] nok-tools`
Details: https://kpt.dev/reference/cli/pkg/get/

### View package content
`kpt pkg tree nok-tools`
Details: https://kpt.dev/reference/cli/pkg/tree/

### Apply the package
```
kpt live init nok-tools
kpt live apply nok-tools --reconcile-timeout=2m --output=table
```
Details: https://kpt.dev/reference/cli/live/
