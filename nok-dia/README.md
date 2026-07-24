# nok-dia

## Description
sample description

## Usage

### Fetch the package
`kpt pkg get REPO_URI[.git]/PKG_PATH[@VERSION] nok-dia`
Details: https://kpt.dev/reference/cli/pkg/get/

### View package content
`kpt pkg tree nok-dia`
Details: https://kpt.dev/reference/cli/pkg/tree/

### Apply the package
```
kpt live init nok-dia
kpt live apply nok-dia --reconcile-timeout=2m --output=table
```
Details: https://kpt.dev/reference/cli/live/
