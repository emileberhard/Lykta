default:
    @just --list

# Run the core and gateway tests
test:
    swift test --package-path Core
    swift test --package-path Gateway

# Run the gateway with LYKTA_* settings from the environment
gateway:
    swift run --package-path Gateway LyktaGateway

# Render layouts with Xcode previews: files, directories, inline JSON or - for stdin
[positional-arguments]
render *args:
    @scripts/render "$@"

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
    harbor run --config evals/job.yaml --ak prompt_template_path=evals/prompt.md --jobs-dir .local/evals --job-name "$job" "$@"
    status=$?
    [ -d ".local/evals/$job" ] && scripts/eval-metrics ".local/evals/$job"
    exit $status

# Compile the app and widgets for iOS without signing
ios:
    xcodebuild -project iOS/Lykta.xcodeproj -scheme Lykta -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
