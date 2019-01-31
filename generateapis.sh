#!/bin/bash

set -x

source toolversions.sh
declare -r CORE_PROTOS_ROOT=$PROTOBUF_TOOLS_ROOT/tools

# This script generates all APIs from the googleapis/googleapis github repository,
# using the code generator from googleapis/gapic-generator.
# It will fetch both repositories if necessary.

# Currently it will only work on Windows due to the way nuget packages installed;
# changing toolversions.sh could mitigate that, if it's ever necessary.
#
# Prerequisites
# - Bash as supplied with Windows git
# - git
# - wget
# - unzip
# - Java 9

OUTDIR=tmp

fetch_github_repos() {
  if [ -d "gapic-generator" ]
  then
    git -C gapic-generator pull -q
    git -C gapic-generator submodule update
  else
    git clone --recursive https://github.com/googleapis/gapic-generator \
      --config core.autocrlf=false \
      --config core.eol=lf
  fi
          
  if [ -d "googleapis" ]
  then
    git -C googleapis pull -q
  else
    # Auto-detect whether we're cloning the public or private googleapis repo.
    git remote -v | grep -q google-cloud-dotnet-private && repo=googleapis-private || repo=googleapis
    git clone --recursive https://github.com/googleapis/${repo} googleapis
  fi
}

generate_api() {
  API_TMP_DIR=$OUTDIR/$1
  API_OUT_DIR=apis
  API_SRC_DIR=googleapis/$2
  API_YAML=$API_SRC_DIR/../$3

  if [[ ! -f $API_YAML ]]
  then
    echo "$API_YAML doesn't exist. Please check inputs."
    exit 1
  fi

  echo Generating $1
  mkdir $API_TMP_DIR
  
  # There should be only one gapic yaml file...
  for i in $API_SRC_DIR/*_gapic.yaml
  do
    cp $i $API_TMP_DIR/gapic.yaml
  done

  # Generate the descriptor set for this API. We always explicitly
  # include IAM so that gRPC rerouting works; it doesn't have any negative
  # impact for non-IAM APIs.
  $PROTOC \
    -I googleapis \
    -I $CORE_PROTOS_ROOT \
    --include_source_info \
    --include_imports \
    -o $API_TMP_DIR/protos.desc \
    $API_SRC_DIR/*.proto \
    googleapis/google/iam/v1/*.proto \
    2>&1 | grep -v "but not used" || true # Ignore import warnings (and grep exit code)


  jvm_args=()
  jvm_args+=(--add-opens=java.base/java.nio=ALL-UNNAMED)
  jvm_args+=(--add-opens=java.base/java.lang=ALL-UNNAMED)
  jvm_args+=(-cp gapic-generator/build/libs/gapic-generator-${GAPIC_GENERATOR_VERSION}-all.jar)
  
  args=()
  args+=(--descriptor_set=$API_TMP_DIR/protos.desc)
  args+=(--service_yaml=$API_YAML)
  args+=(--gapic_yaml=$API_TMP_DIR/gapic.yaml)
  args+=(--output=$API_TMP_DIR)
  args+=(--language=csharp)
  
  # Suppress protobuf warnings in Java 9/10. By the time they
  # become a problem, we won't be using Java...
  java ${jvm_args[*]} com.google.api.codegen.GeneratorMain GAPIC_CODE ${args[*]} \
  2>&1 | grep -v "does not have control environment" || true # Ignore control environment warnings (and grep exit code)
  
  cp -r $API_TMP_DIR/$1 $API_OUT_DIR

  # Generate the C# protos/gRPC directly into the right directory
  # This assumes they all belong to the same API, and are in the same namespace...
  $PROTOC \
    --csharp_out=$API_OUT_DIR/$1/$1 \
    --grpc_out=$API_OUT_DIR/$1/$1 \
    -I googleapis \
    -I $CORE_PROTOS_ROOT \
    --plugin=protoc-gen-grpc=$GRPC_PLUGIN \
    $API_SRC_DIR/*.proto \
    2>&1 | grep -v "but not used" || true # Ignore import warnings (and grep exit code)
    
  if [[ -f $API_OUT_DIR/$1/postgeneration.sh ]]
  then
    echo "Running post-generation script for $1"
    (cd $API_OUT_DIR/$1; ./postgeneration.sh)
  fi
}

# Entry point

install_protoc
install_grpc  
fetch_github_repos
GAPIC_GENERATOR_VERSION=$(cat gapic-generator/version.txt)

# Build GAPIC generator once with gradle so we can invoke it from Java directly
# once per API. We don't care that we're using deprecated Gradle features: we
# won't be using Gradle at all by the end of 2018, with any luck...
(cd gapic-generator; ./gradlew shadowJar --warning-mode=none)

OUTDIR=tmp
rm -rf $OUTDIR
mkdir $OUTDIR

# Generate LongRunning, after changing the license text (because we use
# Apache for LRO where other languages use BSD)
sed -i s/license-header-bsd-3-clause.txt/license-header-apache-2.0.txt/g googleapis/google/longrunning/longrunning_gapic.yaml
generate_api Google.LongRunning google/longrunning longrunning/longrunning.yaml
git -C googleapis checkout google/longrunning/longrunning_gapic.yaml

# IAM (just proto and grpc)
$PROTOC \
  --csharp_out=apis/Google.Cloud.Iam.V1/Google.Cloud.Iam.V1 \
  --grpc_out=apis/Google.Cloud.Iam.V1/Google.Cloud.Iam.V1 \
  -I googleapis \
  -I $CORE_PROTOS_ROOT \
  --plugin=protoc-gen-grpc=$GRPC_PLUGIN \
  googleapis/google/iam/v1/*.proto

# Logging version-agnostic types
$PROTOC \
  --csharp_out=apis/Google.Cloud.Logging.Type/Google.Cloud.Logging.Type \
  -I googleapis \
  -I $CORE_PROTOS_ROOT \
  googleapis/google/logging/type/*.proto

# OS Login version-agnostic types
$PROTOC \
  --csharp_out=apis/Google.Cloud.OsLogin.Common/Google.Cloud.OsLogin.Common \
  -I googleapis \
  -I $CORE_PROTOS_ROOT \
  googleapis/google/cloud/oslogin/common/*.proto

# Now the per-API codegen
generate_api Google.Cloud.Irm.V1Alpha2 google/cloud/irm/v1alpha2 irm_v1alpha2.yaml
