# weblink

weblink allows you to use any device with a web browser as a proxy server.
Simply start weblink and connect your device to it.

## Installation

<img src="weblink.png" alt="weblink" align="right" width="35%">

1. Install Ruby

   - Windows. There are many installation options, for example:

     Option A. Use the Windows Package Manager CLI. Open PowerShell and run:

     ```
     winget install RubyInstallerTeam.RubyWithDevKit.3.4
     ```

     To uninstall:

     ```
     winget uninstall RubyInstallerTeam.RubyWithDevKit.3.4
     ```

     Option B. Go to rubyinstaller.org and install *ruby+devkit* version 2.5 or
     higher.

   - macOS. Ruby is already pre-installed.

   - Linux. You've got this.

1. Install weblink

   Execute the following in Terminal or PowerShell:

   ```
   gem install weblink
   ```

   To uninstall:

   ```
   gem uninstall weblink
   ```

1. Connect you machine to your phone's hotspot.

1. Start weblink

   ```
   weblink
   ```

1. It will output a URL that you need to open on the device you want to use
   as a proxy. Make sure that your firewall is not blocking incoming
   connections.

   Your web browser will be used as a proxy, so it must be running all the
   time. Once you connect your device to weblink, it will start a local HTTPS
   proxy server listening on port 3128, and you will need to route all traffic
   through that proxy.

1. Now weblink is ready. Change the proxy settings in your browser:

   |||
   |---|---|
   | proxy type | `HTTPS` |
   | proxy host | `127.0.0.1` |
   | proxy port | `3128` |

   To test it, you can run:

   ```
   curl -px http://127.0.0.1:3128 https://www.google.com/
   ```

## Development

Pull requests are welcome!

Execute `./test` to run tests.
