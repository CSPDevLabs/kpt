# nok-bng

## Description
bng observability and automation apps for nok

## Usage

### Fetch the package
`kpt pkg get REPO_URI[.git]/PKG_PATH[@VERSION] nok-bng`
Details: https://kpt.dev/reference/cli/pkg/get/

### View package content
`kpt pkg tree nok-bng`
Details: https://kpt.dev/reference/cli/pkg/tree/

### Apply the package
```
kpt live init nok-bng
kpt live apply nok-bng --reconcile-timeout=2m --output=table
```
Details: https://kpt.dev/reference/cli/live/
