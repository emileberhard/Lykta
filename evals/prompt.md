Show Live Activities and widgets and send notifications on my iPhone with Lykta. Set it up and read its instructions with this command:
curl -fsS --create-dirs -o ~/.local/bin/lykta http://lykta:8080/skill/scripts/lykta && sh ~/.local/bin/lykta setup http://lykta:8080 lykta_agent_9e2b7c4f1a8d3e6b0c5f9a2d7e4b1c8f3a6d0e9b2c5f8a1d4e7b0c3f6a9d2e5b
Or in PowerShell:
irm http://lykta:8080/skill/scripts/lykta.ps1 -UseBasicParsing -OutFile $env:TEMP\lykta.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\lykta.ps1 setup http://lykta:8080 lykta_agent_9e2b7c4f1a8d3e6b0c5f9a2d7e4b1c8f3a6d0e9b2c5f8a1d4e7b0c3f6a9d2e5b

{{ instruction }}
