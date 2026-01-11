# nok-bbm

## Description
sample description

## Usage

### Fetch the package
`kpt pkg get REPO_URI[.git]/PKG_PATH[@VERSION] nok-bbm`
Details: https://kpt.dev/reference/cli/pkg/get/

### View package content
`kpt pkg tree nok-bbm`
Details: https://kpt.dev/reference/cli/pkg/tree/

### Apply the package
```
kpt live init nok-bbm
kpt live apply nok-bbm --reconcile-timeout=2m --output=table
```
Details: https://kpt.dev/reference/cli/live/
