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

# Run fresh agents on every eval task against a simulated phone and check what they showed; options go to harbor run
[positional-arguments]
evals *args: image
    harbor run --path evals/tasks --ak prompt_template_path=evals/prompt.md --n-concurrent 16 --jobs-dir .local/evals "$@"

# Compile the app and widgets for iOS without signing
ios:
    xcodebuild -project iOS/Lykta.xcodeproj -scheme Lykta -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
