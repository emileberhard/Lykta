default:
    @just --list

# Run the core and gateway tests, then both lykta scripts against a simulated gateway
test:
    swift test --package-path Core
    swift test --package-path Gateway
    scripts/check-cli

# Run the gateway with LYKTA_* settings from the environment
gateway:
    swift run --package-path Gateway LyktaGateway

# Render layouts with Xcode previews: files, directories, inline JSON or - for stdin
[positional-arguments]
render *args:
    @scripts/render "$@"

# Compose the App Store screenshots into .local/screenshots and the README's images into docs/readme, capturing the app only when its UI changed
screenshots:
    @scripts/screenshots

# Build the gateway container image
image:
    docker build --tag lykta-gateway .

# Run the agents in evals/job.yaml on every eval task against a simulated phone, check what they showed and print their tokens and timings; options go to harbor run
[positional-arguments]
evals *args: image
    #!/usr/bin/env bash
    set -uo pipefail
    for arg in "$@"; do
        case $arg in --job-name* | --jobs-dir* | -o*) echo "just evals chooses its job's name and directory; run harbor run and scripts/eval-metrics directly to choose them." >&2; exit 2 ;; esac
    done
    env_file=${XDG_CONFIG_HOME:-$HOME/.config}/lykta/evals.env
    [ -f "$env_file" ] && set -- --env-file "$env_file" "$@"
    job=$(date +%Y-%m-%d__%H-%M-%S)
    harbor run --config evals/job.yaml --path evals/tasks --ak prompt_template_path=evals/prompt.md --jobs-dir .local/evals --job-name "$job" "$@"
    status=$?
    [ -d ".local/evals/$job" ] && scripts/eval-metrics ".local/evals/$job"
    exit $status

# Compile the app and its extensions for iOS without signing
ios:
    xcodebuild -project iOS/Lykta.xcodeproj -scheme Lykta -destination 'generic/platform=iOS' -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
