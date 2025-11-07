# nok-test

## Description
sample description

## Usage

### Fetch the package
`kpt pkg get REPO_URI[.git]/PKG_PATH[@VERSION] nok-test`
Details: https://kpt.dev/reference/cli/pkg/get/

### View package content
`kpt pkg tree nok-test`
Details: https://kpt.dev/reference/cli/pkg/tree/

### Apply the package
```
kpt live init nok-test
kpt live apply nok-test --reconcile-timeout=2m --output=table
```
Details: https://kpt.dev/reference/cli/live/
