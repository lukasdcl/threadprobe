# threadprobe

Diagnose a **Thread / Matter-over-Thread** network from an ordinary computer on the same LAN.

Most Thread tools look at the mesh from inside one ecosystem: a Home Assistant dashboard, a vendor app, a border router's own web page. But many real-world problems ("the light spins for ten seconds, then works") happen *between* the mesh and the controllers on your LAN: stale routes, dead addresses being announced, border routers disagreeing with each other. `threadprobe` looks at the network the way any controller on your LAN sees it, and tells you what is wrong in plain language.

It is a single shell script. It runs on **macOS** and **Linux** and needs no installation.

## What it checks

1. **Thread border routers** announced on the LAN (`_meshcop._udp`): vendor, Thread version, network name, extended PAN ID, partition ID, state (interface active? role? backbone router?) and the off-mesh-routable prefix, i.e. the address range Thread devices use.
   - Flags **split networks** (border routers in different partitions) and **multiple Thread networks**.
   - Recognises firmware that publishes the partition ID byte-reversed, so that quirk isn't reported as a split.
   - Flags **more than one device address range** being advertised.
2. **Border router peering** over the LAN (TREL and SRP replication).
3. **Routes** your computer has learned towards private (ULA) prefixes, and which border router each one goes through.
   - Flags routes to ranges **no border router advertises**, and routes via routers that are **no longer border routers** (typically left over after a border router restarts).
   - Flags a missing route to the Thread device range.
4. **IPv6 routers** heard on the LAN, labelled with the border router they belong to.
5. **Whether this computer is itself on the mesh.** Some recent Macs have a Thread radio. If so, it decodes the computer's routing locator, showing whether it attached as a child or a router.
6. **Every Matter device** announced on the LAN (`_matter._tcp`): which controllers (fabrics) it belongs to and its node ID in each, its advertised retry timings (SII/SAI/SAT), every address it announces, the route to each, and ping results for each.
   - Flags **announced addresses that don't answer**. This is the classic cause of "spinner, then eventually works": a controller tries the dead address, times out, retries, then finds the working one.
   - Flags devices with no reachable address and devices that answer slowly.
   - Flags devices that belong to many controllers.
7. **Optional entry-point test** (`--entry-test`): pings every Thread device *through each border router in turn*, so you can see whether the way into the mesh matters.

Everything ends with a **summary** of problems found.

## Requirements

| | macOS | Linux |
|---|---|---|
| Shell | bash 3.2+ (built in) | bash |
| mDNS | `dns-sd` (built in) | `avahi-browse` (package `avahi-utils` or `avahi-tools`) with `avahi-daemon` running |
| Network tools | `netstat`, `ndp`, `route`, `ping6` (built in) | `ip` (iproute2), `ping` |
| Parsing | `perl` (built in) | `perl` (installed on nearly every distribution) |

The computer must be on the same LAN segment (VLAN) as your border routers, with IPv6 enabled. That's the normal case, because Matter controllers need the same.

## Usage

```sh
curl -O https://raw.githubusercontent.com/lukasdcl/threadprobe/main/threadprobe.sh
bash threadprobe.sh
```

Or clone the repository and run `bash threadprobe.sh`.

The report is printed and saved as `reports/threadprobe-<date>-<time>.txt` in a `reports` folder next to the script (or in `./reports` if the script's folder isn't writable). Use `--dir` to choose another folder, or `--output` for an exact file name.

```
Options:
  -d, --dir DIR          Folder to save reports in (default: reports/ next to the script)
  -o, --output FILE      Write the report to exactly FILE instead
  -c, --count N          Pings per address (default 10)
  -t, --browse-time S    Seconds to listen for mDNS announcements (default 6)
  -e, --entry-test       Also ping every Thread device through each border router
                         in turn (needs root; uses sudo; routes are removed after)
  -i, --interface IF     LAN interface for --entry-test (default: auto-detect)
  -r, --redact           Replace addresses, names and network identifiers with
                         placeholders, so the report can be shared publicly
  -n, --no-ping          Skip reachability tests
  -q, --quiet            Only write the file, don't print the report
  -k, --keep-raw DIR     Keep the raw collected data in DIR (NOT redacted;
                         e.g. threadprobe-raw, which git ignores)
  -h, --help             Show help
```

### Getting the most out of it

- **Run it while the problem is happening**, then again when everything works, and compare the two reports. Intermittent Thread problems often leave no trace once they've cleared.
- **Restarting a border router can cause problems for a while.** Run it soon after one restarts; that's when stale routes and short-lived address ranges tend to show up.
- To share a report in a forum or an issue, use `--redact`. Each address, name and identifier is replaced with a placeholder (`P1::i3`, `br2`, `dev5`, `fabric1`), consistently, so the report still makes sense.

## Reading the report

| You see | What it means |
|---|---|
| `announces X, which does not answer` | The device is telling controllers to use an address that goes nowhere. Controllers time out and retry, which shows up as delays or "not responding". Power-cycling the device usually makes it re-register with a working address. If it comes back with the bad address again, look for the border router advertising that range. |
| `NOT an advertised Thread device range` | A router on the LAN is advertising a route to a range that no border router lists as the Thread device range. Often a border router briefly invented its own range while restarting. |
| `not the current address of any announced border router` | Your computer is still routing Thread traffic via an old address, typically of a border router that has restarted. It expires on its own (usually within 2 hours). |
| `split into N partitions` | The mesh has broken into islands that can't reach each other. Usually caused by poor radio coverage between groups of devices, or a border router that formed its own network. |
| `this computer's own Thread interface` / `CHILD (end device)` | Your computer is on the mesh itself (some recent Macs have a Thread radio). As a child, it hands everything through a parent router and only collects replies periodically, so its own ping times can be much higher than other controllers see. |
| High `SII` (e.g. `SII=2000`) | The device asks controllers to wait that many milliseconds before retrying when it's idle. A single lost packet then costs at least that much delay. |
| `probably sleepy` | The device's idle retry interval is 4 seconds or more, which usually means a battery or low-power device that sleeps between check-ins. Slow replies are expected, so it's listed as a note rather than a problem. |
| `outside the advertised Thread device range` | The device holds, and announces, an address in a range the border routers don't advertise for Thread devices. Typically a border router briefly offered its own range while restarting, and the device kept the address. |
| `role not reported by this firmware` | Thread 1.3 and earlier border routers don't fill in the role field of their status announcement, so it isn't treated as "detached". |
| `belongs to N controllers` | Each controller (Apple Home, Google Home, Home Assistant, a vendor app and so on) keeps its own sessions with the device. Many devices only support 5, and leftovers from old setups take up slots. |
| `node 112233` | The default node ID many open-source Matter controllers give themselves. It shows which controller is self-hosted, and can reveal forgotten test setups. |

## Safety and privacy

- **Read-only by default.** It listens for mDNS announcements, reads your routing table and sends pings. It changes nothing.
- **`--entry-test`** temporarily adds one host route per Thread device address. It never replaces a route you already have, and it only removes routes it added: when each round finishes, and again on exit or Ctrl-C. A reboot also clears them.
- **Nothing is uploaded.** The only traffic it sends is pings to the addresses your devices announce. The report is a local text file.
- **Data from the network is treated as untrusted.** Device and router names are never executed, never used as file names, and control characters are escaped before printing, so a maliciously named device can't inject terminal escape sequences.
- **Unredacted reports contain your network's private addresses and device names.** Use `--redact` before sharing. `--keep-raw` data is *not* redacted. If you run it inside a clone of this repository, the default `reports/` folder and a `threadprobe-raw` folder are git-ignored; reports saved elsewhere with `--dir` or `--output` are not.

## Limitations

- It sees what a LAN host can see. It can't look inside a vendor's hub (for example how Apple Home or Google Home choose addresses or reuse sessions), and it doesn't sniff the radio. For radio-level analysis, use an 802.15.4 sniffer such as Nordic's nRF Sniffer with Wireshark.
- Thread devices that don't use Matter don't announce `_matter._tcp`, so they only show up indirectly.
- Ping measures reachability and round-trip time, not Matter's own retry behaviour. A device can respond slowly to ping yet work, and vice versa, but a dead announced address is always a problem.
- The state bitmap (`sb`) is decoded using the OpenThread border agent layout. Other implementations are expected to follow it, but the raw value is printed too.

## Contributing

Bug reports with a `--redact`ed report are very welcome, especially from ecosystems the author doesn't own. If parsing goes wrong, `--keep-raw DIR` saves the raw data, but check it for anything private before sharing.

## License

MIT. See [LICENSE](LICENSE).
