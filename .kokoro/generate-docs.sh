#!/bin/bash
# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Update 2024-08-12: We are using python3.10 explicitly everywhere to
# avoid `test(3.10)` failures.

# Should run regardless of failure status for the generator.
set +eo pipefail

# Disable buffering, so that the logs stream through.
export PYTHONUNBUFFERED=1

export PATH="${HOME}/.local/bin:${PATH}"

# If running locally, copy a service account file to
# /dev/shm/73713_docuploader_service_account before calling ci/trampoline_v2.sh.
export GOOGLE_APPLICATION_CREDENTIALS=$KOKORO_KEYSTORE_DIR/73713_docuploader_service_account

# Configure Google Cloud SDK to use service account details for gsutil commands.
gcloud auth activate-service-account --key-file ${GOOGLE_APPLICATION_CREDENTIALS}

# Install dependencies.
# Disable dependency resolver as all dependencies should have been laid out.
python3.10 -m pip install --no-deps --require-hashes -r .kokoro/requirements.txt
python3.10 -m pip install -e .

# Store the contents of bucket log in a variable to reuse.
python_bucket_items=$(gsutil ls "gs://docs-staging-v2/docfx-python*")
# Store empty tarballs that did not produce any content to check later.
empty_packages=""
# Store monorepo packages to process later
monorepo_packages=""
# Retrieve unique repositories to regenerate the YAML with.
for package in $(echo "${python_bucket_items}" | cut -d "-" -f 5- | rev | cut -d "-" -f 2- | rev | uniq); do

  # Extract the latest version of the package to grab latest metadata.
  version=$(echo "${python_bucket_items}" | grep "docfx-python-${package}-" | rev | cut -d "-" -f 1 | rev | sort -V -r | head -1)

  # Set the bucket and tarball values to be used for the package.
  bucket_item=$(echo "gs://docs-staging-v2/docfx-python-${package}-${version}")
  tarball=$(echo ${bucket_item} | cut -d "/" -f 4)

  # Make temporary directory to extract tarball content.
  mkdir ${tarball}
  cd ${tarball}

  # Retrieve the GitHub Repository info.
  gsutil cp ${bucket_item} .
  tar -zxvf ${tarball}
  repo=$(cat docs.metadata | grep "github_repository:" | cut -d "\"" -f 2 | cut -d "/" -f 2)

  # If the pacakage is part of the monorepo, we'll process this later.
  if [[ "${repo}" == "google-cloud-python" ]]; then
    # Add an extra whitespace at the end to be used as a natural separator.
    monorepo_packages+="$(cat docs.metadata | grep "distribution_name" | cut -d "\"" -f 2) "
    cd ..
    rm -rf ${tarball}
    continue
  fi

  # Clean up the tarball content.
  cd ..
  rm -rf ${tarball}

  # Clone the repository.
  git clone "https://github.com/googleapis/${repo}.git"

  # For each repo, process docs and docfx jobs to regenerate the YAML.
  cd ${repo}

  # Save the noxfile for usage throughout different releases.
  cp "noxfile.py" ../

  if [[ ${FORCE_GENERATE_ALL_TAGS} == "true" ]]; then
    # Grabs all tags from the repository.
    GITHUB_TAGS=$(git tag --sort=-v:refname)
  else
    # Grab the latest released tag.
    GITHUB_TAGS=$(git describe --tags `git rev-list --tags --max-count=1`)
  fi

  for tag in ${GITHUB_TAGS}; do
    # Ensure noxfile.py is reverted so merge conflicts do not occur.
    git restore "noxfile.py"
    git checkout ${tag}

    # Use the latest noxfile for all tags.
    cp ../"noxfile.py" .

    # TODO: support building all googleapis.dev docs through an environmental variable option passed.
    ## Build HTML docs for googleapis.dev.
    # nox -s docs

    # python3.10 -m docuploader create-metadata \
    #  --name=$(jq --raw-output '.name // empty' .repo-metadata.json) \
    #  --version=$(python3.10 setup.py --version) \
    #  --language=$(jq --raw-output '.language // empty' .repo-metadata.json) \
    #  --distribution-name=$(python3.10 setup.py --name) \
    #  --product-page=$(jq --raw-output '.product_documentation // empty' .repo-metadata.json) \
    #  --github-repository=$(jq --raw-output '.repo // empty' .repo-metadata.json) \
    #  --issue-tracker=$(jq --raw-output '.issue_tracker // empty' .repo-metadata.json)

    # cat docs.metadata

    ## upload docs
    # python3.10 -m docuploader upload docs/_build/html --metadata-file docs.metadata --staging-bucket "${STAGING_BUCKET}"

    # Test running with the plugin version locally.
    if [[ "${TEST_PLUGIN}" == "true" ]]; then
      # --no-use-pep517 is required for django-spanner install issue: see https://github.com/pypa/pip/issues/7953
      python3.10 -m pip install --user --no-use-pep517 -e .[all]
      sphinx-build -T -N -D extensions=sphinx.ext.autodoc,sphinx.ext.autosummary,docfx_yaml.extension,sphinx.ext.intersphinx,sphinx.ext.coverage,sphinx.ext.napoleon,sphinx.ext.todo,sphinx.ext.viewcode,recommonmark -b html -d docs/_build/doctrees/ docs/ docs/_build/html/
      continue
    fi

    # Build YAML tarballs for Cloud-RAD.
    nox -s docfx

    # Check that documentation is produced. If not, log and continue.
    if [ ! "$(ls docs/_build/html/docfx_yaml/)" ]; then
      empty_packages="${repo}-${tag} ${empty_packages}"
      continue
    fi

    # Update specific names to be up to date.
    name=$(jq --raw-output '.name // empty' .repo-metadata.json)
    if [[ "${name}" == "translation" ]]; then
      name="translate"
    fi
    if [[ "${name}" == "clouderroreporting" ]]; then
      name="clouderrorreporting"
    fi
    if [[ "${name}" == "iamcredentials" ]]; then
      name="iam"
    fi

    python3.10 -m docuploader create-metadata \
      --name=${name} \
      --version=$(python3.10 setup.py --version) \
      --language=$(jq --raw-output '.language // empty' .repo-metadata.json) \
      --distribution-name=$(python3.10 setup.py --name) \
      --product-page=$(jq --raw-output '.product_documentation // empty' .repo-metadata.json) \
      --github-repository=$(jq --raw-output '.repo // empty' .repo-metadata.json) \
      --issue-tracker=$(jq --raw-output '.issue_tracker // empty' .repo-metadata.json)

    cat docs.metadata

    # upload docs
    python3.10 -m docuploader upload docs/_build/html/docfx_yaml --metadata-file docs.metadata --destination-prefix docfx --staging-bucket "${V2_STAGING_BUCKET}"
  done

  # Clean up the repository to make room.
  cd ../
  rm -rf ${repo}
  rm "noxfile.py"
done

# Build documentation for monorepo packages
if [ -n "${monorepo_packages}" ]; then
  echo "Processing monorepo packages"
  git clone "https://github.com/googleapis/google-cloud-python.git"
  cd google-cloud-python/packages

  # TODO (https://github.com/googleapis/sphinx-docfx-yaml/issues/287): support
  # multi-version build for the monorepo.
  for monorepo_package in $(echo ${monorepo_packages}); do
    cd ${monorepo_package}

    # Test running with the plugin version locally.
    if [[ "${TEST_PLUGIN}" == "true" ]]; then
      # --no-use-pep517 is required for django-spanner install issue: see https://github.com/pypa/pip/issues/7953
      python3.10 -m pip install --user --no-use-pep517 -e .[all]
      sphinx-build -T -N -D extensions=sphinx.ext.autodoc,sphinx.ext.autosummary,docfx_yaml.extension,sphinx.ext.intersphinx,sphinx.ext.coverage,sphinx.ext.napoleon,sphinx.ext.todo,sphinx.ext.viewcode,recommonmark -b html -d docs/_build/doctrees/ docs/ docs/_build/html/
      continue
    fi

    # Build YAML tarballs for Cloud-RAD.
    nox -s docfx

    # Check that documentation is produced. If not, log and continue.
    if [ ! "$(ls docs/_build/html/docfx_yaml/)" ]; then
      empty_packages="${monorepo_package} ${empty_packages}"
      continue
    fi

    python3.10 -m docuploader create-metadata \
      --name=$(jq --raw-output '.name // empty' .repo-metadata.json) \
      --version=$(python3.10 setup.py --version) \
      --language=$(jq --raw-output '.language // empty' .repo-metadata.json) \
      --distribution-name=$(python3.10 setup.py --name) \
      --product-page=$(jq --raw-output '.product_documentation // empty' .repo-metadata.json) \
      --github-repository=$(jq --raw-output '.repo // empty' .repo-metadata.json) \
      --issue-tracker=$(jq --raw-output '.issue_tracker // empty' .repo-metadata.json)

    cat docs.metadata

    # upload docs
    python3.10 -m docuploader upload docs/_build/html/docfx_yaml --metadata-file docs.metadata --destination-prefix docfx --staging-bucket "${V2_STAGING_BUCKET}"

    # Clean up the package to make room.
    cd ../
    rm -rf ${monorepo_package}
  done
  cd ../../
  rm -rf google-cloud-python
fi

if [ ! "${empty_packages}" ]; then
  exit
fi

echo "The following packages did not produce any content:"
for empty_package in $(echo ${empty_packages}); do
  echo ${empty_package}
done
