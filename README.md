# EFXTv WiFi Audit Toolkit - Complete Details, Features & Ethical Usage Guide

<img width="800" height="450" alt="image" src="https://github.com/user-attachments/assets/8dcdefc8-f85c-4064-b185-04209a389b8e" />




## 1. DETAILS

- **Tool Name:** EFXTv WiFi Audit Toolkit
- **Script Name:** `wifibee.sh`
- **Tool Type:** Linux Wireless Network Security Auditing Toolkit
- **Interface:** Interactive terminal menu with arrow-key navigation
- **Programming Languages:** Bash and Python 3
- **Primary Purpose:** Wireless network discovery, security assessment, authentication handshake capture, and authorized password-strength testing
- **Supported Environment:** Linux systems with compatible wireless adapters and required dependencies
- **Privileges:** Root or sudo privileges are required for many wireless operations
- **Main Wireless Utilities:** Aircrack-ng suite and `iw`
- **Authorization Requirement:** Only test networks you own or have explicit permission to assess

## 2. FEATURES of pro version

### A. Interactive Terminal Interface

- Arrow-key navigation using Up and Down keys
- Enter key to select options
- Q or Esc to return to previous menus
- Interactive wireless adapter selection
- Interactive access-point selection
- Interactive client selection
- Guided workflow for wireless auditing
- Menu-based access to scanning and security-testing functions

### B. Wireless Adapter Management

- Detects available wireless interfaces
- Displays wireless interface information
- Checks the current interface mode
- Supports enabling monitor mode
- Supports disabling monitor mode
- Uses `airmon-ng` and `iw` for interface management
- Attempts to restore normal networking after testing

### C. Wi-Fi Network Discovery

- Scans nearby wireless access points
- Identifies visible Wi-Fi network names (ESSIDs)
- Displays access-point MAC addresses (BSSIDs)
- Displays wireless channel information
- Reports signal-power values
- Displays advertised encryption information
- Supports configurable scan durations
- Provides access-point selection through an interactive menu
- Supports rescanning nearby networks
- Saves scan results to CSV files

### D. Wireless Client Discovery

- Observes wireless stations transmitting within range
- Filters observed clients by the selected access point
- Displays station MAC addresses
- Displays signal-power information
- Associates observed stations with available BSSID information
- Supports interactive client selection
- Saves client observations to CSV files
- Helps administrators document devices in an authorized test environment

### E. Authentication Handshake Capture

- Uses `airodump-ng` to capture wireless traffic
- Targets a selected access point and channel
- Allows the user to specify an output filename prefix
- Saves capture data in `.cap` files
- Supports manual capture termination using Ctrl+C
- Can support authorized WPA/WPA2 password-strength assessments when suitable authentication data is captured
- Does not directly reveal a Wi-Fi password merely by capturing a handshake

### F. Deauthentication Testing

- Provides an active deauthentication testing function
- Supports selecting an observed wireless client
- Includes a broadcast-client option
- Allows the user to specify a packet count
- Supports stopping an active operation with Ctrl+C
- Uses `aireplay-ng` for frame transmission
- Includes handling for certain wireless channel-detection errors

**Ethical restriction:** This function can interrupt wireless connectivity. Use it only on an isolated lab network or within an explicitly authorized, controlled availability test.

### G. Password-Strength Testing

- Uses `aircrack-ng` to analyze compatible capture files
- Supports selecting capture files through an interactive menu
- Supports wordlist-based password testing
- Can use `rockyou.txt` as a password candidate list
- Helps demonstrate the risk of common or predictable passwords
- Supports authorized security assessments of password-based wireless authentication

A failed password-recovery attempt does not prove that a password is unbreakable.

### H. Wireless Injection Testing

- Includes an injection-test function
- Uses `aireplay-ng` for wireless injection capability testing
- Supports specifying a wireless interface
- Depends on adapter, chipset, driver, and regulatory capabilities

### I. Automatic Dependency Setup

- Detects the available Linux package manager
- Supports APT-based distributions
- Supports DNF and YUM
- Supports Pacman
- Supports Zypper
- Supports APK
- Supports XBPS
- Supports Portage
- Installs required wireless utilities and supporting packages
- Provides setup instructions for missing dependencies
- May download a password wordlist with user consent

### J. Network Restoration

- Attempts to stop monitor-mode interfaces
- Attempts to restart NetworkManager
- Attempts to restart `wpa_supplicant`
- Re-enables Wi-Fi through NetworkManager utilities
- Attempts to bring wireless interfaces back up
- Provides a manual restoration command
- Attempts cleanup when the interactive wizard exits

Restoration is best-effort and is not guaranteed to resolve every driver or networking issue.

## 3. REQUIRED DEPENDENCIES

- `iw` - Wireless interface inspection and configuration
- `airmon-ng` - Monitor-mode management
- `airodump-ng` - Wireless scanning and packet capture
- `aireplay-ng` - Wireless injection and active testing
- `aircrack-ng` - Capture analysis and password testing
- `timeout` - Limits the duration of selected operations
- `python3` - Parses scan output
- `iproute2` utilities - Interface management
- `NetworkManager` utilities - Network restoration on compatible systems
- `wpa_supplicant` - Wireless connection management on applicable systems

## 4. COMMANDS AND OPTIONS

- `wifibee` - Displays the main help screen
- `wifibee --help` - Displays usage information
- `wifibee --start` - Launches the interactive auditing wizard
- `wifibee --setup` - Displays or performs dependency setup
- `wifibee --setup --yes` - Runs setup with automatic confirmation where supported
- `wifibee --h` - Displays extended help
- `wifibee enable` - Opens wireless interface selection for monitor-mode setup
- `wifibee disable` - Opens interface selection for monitor-mode shutdown
- `wifibee restore` - Attempts to restore networking
- `wifibee internet` - Alias for network restoration
- `wifibee fixwifi` - Alias for network restoration
- `wifibee scan` - Starts an interactive wireless scan
- `wifibee clients` - Discovers observed wireless clients
- `wifibee capture` - Starts a capture for a specified or selected target
- `wifibee deauth` - Opens or invokes active deauthentication testing
- `wifibee crack` - Opens capture-file password testing
- `wifibee kill` - Runs the wireless injection-test function

These commands expose different levels of functionality. Some require a configured monitor interface or additional target parameters.

## 5. OUTPUT FILES

- `wifibee_scan_raw.csv` - Access-point scan results
- `wifibee_clients_raw.csv` - Observed client information
- `*-01.cap` - Capture output generated from the selected filename prefix
- `/tmp/wifibee_scan-*.csv` - Temporary access-point scan output
- `/tmp/wifibee_st-*.csv` - Temporary client scan output
- `rockyou.txt` - Optional password candidate wordlist

Capture files and client inventories should be treated as sensitive data.

## 6. ETHICAL AND LEGAL LIMITS

- Only audit Wi-Fi networks you own or have explicit permission to test.
- Obtain written authorization before conducting assessments for an organization or another person.
- Define the permitted access points, devices, test window, and allowed testing methods.
- Use passive scanning for routine network discovery whenever possible.
- Do not collect or retain unnecessary personal or device information.
- Do not attempt to recover passwords for networks you do not administer or have permission to test.
- Do not disconnect other people's devices.
- Do not perform broadcast deauthentication against public or shared networks.
- Avoid testing that could interrupt business operations, emergency communications, or other critical services.
- Store capture files securely and delete them when no longer required.
- Do not publish captured authentication data, private network details, or recovered credentials.
- Stop immediately if a test affects devices or networks outside the approved scope.

## 7. SECURITY RECOMMENDATIONS

- Prefer WPA3-Personal where supported, or properly configured WPA2-AES.
- Use a long, unique Wi-Fi passphrase.
- Disable WPS if it is unnecessary.
- Enable Protected Management Frames where supported.
- Keep router firmware and wireless drivers updated.
- Replace unsupported routers and obsolete wireless security configurations.
- Review connected-device inventories using authorized router administration tools.
- Use a dedicated test access point and test clients for active security experiments.
- Document findings, evidence, impact, and recommended remediation.

## 8. IMPORTANT TECHNICAL LIMITATIONS

- Monitor mode requires compatible hardware and drivers.
- Not every wireless adapter supports frame injection.
- Scan results may omit devices that are not transmitting.
- Signal-power values are not precise distance measurements.
- Captured handshakes do not automatically disclose passwords.
- Wordlist-based password testing cannot guarantee password recovery.
- Modern wireless protections can prevent some active attacks.
- Automatic network restoration may fail on some Linux configurations.
- Installing dependencies may modify system packages.
- The script coordinates external utilities; its presence does not guarantee that each operation succeeds.

## 9. SUMMARY

EFXTv WiFi Audit Toolkit is a Bash-based Linux wireless auditing interface that combines network discovery, client observation, monitor-mode management, packet capture, active wireless testing, and offline password-strength assessment.

Its most appropriate uses are authorized network inventory, wireless security education, controlled laboratory testing, and validating defensive configurations.

**The safest workflow is to begin with passive discovery, document the network's configuration, review its security settings, and reserve disruptive testing for an isolated environment with explicit authorization.**

Add a quick-start workflowSeparate safe and disruptive features wifibee -h
