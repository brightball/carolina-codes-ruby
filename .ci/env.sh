# Source from the workspace root after restoring the prepared CI tree.
export PATH="${PWD}/.ci/bin:${PATH}"
export PYTHONPATH="${PWD}/.ci/pypkgs${PYTHONPATH:+:${PYTHONPATH}}"
export BUNDLE_PATH="${PWD}/vendor/bundle"
