default:
    @just --list

# Run the core and gateway tests
test:
    swift test --package-path Core
    swift test --package-path Gateway

# Run the gateway with LYKTA_* settings from the environment
gateway:
    swift run --package-path Gateway LyktaGateway

# Build the gateway container image
image:
    docker build --tag lykta-gateway .

# Compile the app and widgets for iOS without signing
ios:
    xcodebuild -project Lykta.xcodeproj -scheme Lykta -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
