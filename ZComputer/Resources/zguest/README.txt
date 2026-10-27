CI copies the static guest-agent binaries (zguest-linux-arm64, zguest-linux-amd64) from the `guest` job into
this folder before building. The app hands this folder (Contents/Resources/zguest) to VMController as
`guestAgentDirectory`; it is shared read-only into Linux guests. The binaries only ever run inside the guest.
