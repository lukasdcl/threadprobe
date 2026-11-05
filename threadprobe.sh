#!/usr/bin/env bash
#
# threadprobe - diagnose a Thread / Matter-over-Thread network from an
# ordinary computer on the same LAN.
#
# It looks at the network the way any controller on your LAN sees it:
# the Thread border routers announced over mDNS, the IPv6 routes your
# computer has learned towards the Thread mesh, the addresses every Matter
# device announces, and whether those addresses actually answer.
#
# Read-only by default. The optional --entry-test temporarily adds host
# routes (needs root) and removes them again when it finishes.
#
# Runs on macOS (bash 3.2 or later, uses dns-sd) and Linux (uses avahi).
# Requires perl, which ships with macOS and nearly every Linux distribution.
#
# SPDX-License-Identifier: MIT

VERSION="1.0.0"
PROG=${0##*/}

# ---------------------------------------------------------------- options --

OUT=""
REPORTDIR=""
COUNT=10
BROWSE=6
ENTRY=0
IFACE=""
REDACT=0
NOPING=0
QUIET=0
KEEPDIR=""

usage() {
  cat <<EOF
$PROG $VERSION - diagnose a Thread / Matter-over-Thread network from the LAN

Usage: $PROG [options]

Options:
  -d, --dir DIR          Folder to save reports in (default: a "reports" folder
                         next to this script, or ./reports if that isn't writable)
  -o, --output FILE      Write the report to exactly FILE instead
  -c, --count N          Pings per address (default: $COUNT)
  -t, --browse-time S    Seconds to listen for mDNS announcements (default: $BROWSE)
  -e, --entry-test       Also ping every Thread device through each border router
                         in turn, by adding temporary host routes. Needs root
                         (uses sudo). Routes are removed when the test ends.
  -i, --interface IF     LAN interface for --entry-test (default: auto-detect)
  -r, --redact           Replace addresses, names and network identifiers with
                         stable placeholders, so the report can be shared publicly
  -n, --no-ping          Skip all reachability tests (announcements and routes only)
  -q, --quiet            Don't print the report to the terminal, only to the file
  -k, --keep-raw DIR     Keep the raw collected data in DIR (for bug reports;
                         NOT redacted; e.g. threadprobe-raw, which git ignores)
  -h, --help             Show this help
  -V, --version          Show the version

Run it while your problem is happening, and again when things are working,
then compare the two reports.
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
isnum() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output)      [ $# -ge 2 ] || die "$1 needs a value"; OUT=$2; shift 2;;
    -d|--dir)         [ $# -ge 2 ] || die "$1 needs a value"; REPORTDIR=$2; shift 2;;
    -c|--count)       [ $# -ge 2 ] || die "$1 needs a value"; COUNT=$2; shift 2;;
    -t|--browse-time) [ $# -ge 2 ] || die "$1 needs a value"; BROWSE=$2; shift 2;;
    -e|--entry-test)  ENTRY=1; shift;;
    -i|--interface)   [ $# -ge 2 ] || die "$1 needs a value"; IFACE=$2; shift 2;;
    -r|--redact)      REDACT=1; shift;;
    -n|--no-ping)     NOPING=1; shift;;
    -q|--quiet)       QUIET=1; shift;;
    -k|--keep-raw)    [ $# -ge 2 ] || die "$1 needs a value"; KEEPDIR=$2; shift 2;;
    -h|--help)        usage; exit 0;;
    -V|--version)     echo "$PROG $VERSION"; exit 0;;
    *)                usage >&2; die "unknown option: $1";;
  esac
done

isnum "$COUNT"  && [ "$COUNT" -ge 1 ]  && [ "$COUNT" -le 100 ] || die "--count must be 1-100"
isnum "$BROWSE" && [ "$BROWSE" -ge 1 ] && [ "$BROWSE" -le 60 ] || die "--browse-time must be 1-60"
case "$IFACE" in *[!A-Za-z0-9_.-]*) die "invalid interface name: $IFACE";; esac
[ "$ENTRY" = 1 ] && [ "$NOPING" = 1 ] && die "--entry-test and --no-ping can't be combined"

# --------------------------------------------------------------- platform --

OS=$(uname -s)
case "$OS" in
  Darwin) PLATFORM=mac ;;
  Linux)  PLATFORM=linux ;;
  *)      die "unsupported OS: $OS (macOS and Linux only)" ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"; }
need perl "Install perl and try again."
if [ "$PLATFORM" = mac ]; then
  need dns-sd  "It is part of macOS; is this a normal macOS install?"
  need netstat ""
  need ndp     ""
  if command -v ping6 >/dev/null 2>&1; then PING="ping6"
  else need ping ""; PING="ping -6"; fi
else
  need avahi-browse "Install avahi-utils (Debian/Ubuntu) or avahi-tools (Fedora), and make sure avahi-daemon is running."
  need ip "Install iproute2."
  if command -v ping6 >/dev/null 2>&1; then PING="ping6"
  else need ping "Install iputils-ping."; PING="ping -6"; fi
fi

log() { [ "$QUIET" = 1 ] || printf '%s\n' "$*" >&2; }

# --------------------------------------------------------------- workspace --

W=$(mktemp -d 2>/dev/null || mktemp -d -t threadprobe) || die "can't create a temporary directory"
ADDED="$W/added_routes"; : > "$ADDED"
KEEPALIVE=""
SUDO=""

cleanup() {
  if [ -s "$ADDED" ]; then
    while IFS= read -r a; do route_del "$a"; done < "$ADDED"
    : > "$ADDED"
  fi
  [ -n "$KEEPALIVE" ] && kill "$KEEPALIVE" 2>/dev/null
  if [ -n "$KEEPDIR" ]; then mkdir -p "$KEEPDIR" && cp -R "$W"/. "$KEEPDIR"/ 2>/dev/null; fi
  rm -rf "$W"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ------------------------------------------------------------ perl helper --
# All parsing and the report itself live here. Data from the network is
# treated as untrusted: it is never executed, never used in file names, and
# control characters are escaped before anything is printed.

cat > "$W/helper.pl" <<'PERL'
use strict; use warnings;
no warnings qw(portable uninitialized);

my $mode = shift(@ARGV) // '';

# ---- generic helpers
my %FIXED = (xp => 8, pt => 4, at => 8, sb => 4, xa => 8, id => 16, bb => 2, dd => 8);

sub unesc { my $s = shift // ''; $s =~ s/\\(\d{3})/chr($1 % 256)/ge; $s =~ s/\\(.)/$1/g; return $s; }
sub flat  { my $s = shift // ''; $s =~ s/[\t\r\n]/ /g; return $s; }
sub safe  { my $s = shift // ''; $s =~ s/([\x00-\x1f\x7f])/sprintf('\\x%02x', ord $1)/ge; return $s; }

sub expand6 {
  my $a = lc(shift // ''); $a =~ s/%.*//;
  return undef unless $a =~ /^[0-9a-f:]+$/ && $a =~ /:/;
  my @p;
  if ($a =~ /::/) {
    return undef if $a =~ /::.*::/;
    my ($l, $r) = split /::/, $a, 2;
    my @l = length $l ? split(/:/, $l, -1) : ();
    my @r = length $r ? split(/:/, $r, -1) : ();
    my $fill = 8 - @l - @r; return undef if $fill < 1;
    @p = (@l, ('0') x $fill, @r);
  } else { @p = split /:/, $a, -1; }
  return undef unless @p == 8;
  for (@p) { return undef unless /^[0-9a-f]{1,4}$/; }
  return join ':', map { sprintf '%04x', hex $_ } @p;
}

sub compress6 {
  my $e = shift;
  my @g = map { my $x = $_; $x =~ s/^0+(?=.)//; $x } split /:/, $e;
  my ($bs, $bl, $cs, $cl) = (-1, 0, -1, 0);
  for my $i (0 .. 7) {
    if ($g[$i] eq '0') { $cs = $i if $cl == 0; $cl++; ($bs, $bl) = ($cs, $cl) if $cl > $bl; }
    else { $cl = 0; }
  }
  return join(':', @g) if $bl < 2;
  return join(':', @g[0 .. $bs - 1]) . '::' . join(':', @g[$bs + $bl .. 7]);
}

sub hex32 { (my $h = shift) =~ s/://g; return $h; }
sub parse_prefix {
  my $p = shift // ''; return undef if $p eq 'default';
  my ($a, $len) = split m{/}, $p, 2; $len = 128 unless defined $len && $len =~ /^\d+$/ && $len <= 128;
  my $e = expand6($a) or return undef;
  return { e => $e, len => $len };
}
sub in_prefix {
  my ($e, $P) = @_; my $n = int($P->{len} / 4);
  my ($h1, $h2) = (hex32($e), hex32($P->{e}));
  return 0 unless substr($h1, 0, $n) eq substr($h2, 0, $n);
  my $rem = $P->{len} % 4; return 1 unless $rem;
  my $m = (0xF << (4 - $rem)) & 0xF;
  return (hex(substr($h1, $n, 1)) & $m) == (hex(substr($h2, $n, 1)) & $m);
}
sub is_ll  { return $_[0] =~ /^fe[89ab]/; }
sub is_ula { return $_[0] =~ /^f[cd]/; }

# ---- TXT record decoding (binary safe)
sub dec_char {
  my ($s, $ir) = @_; my $c = substr($s, $$ir, 1);
  if ($c eq "\\") {
    my $d = substr($s, $$ir + 1, 3);
    if ($d =~ /^\d{3}$/) { $$ir += 4; return chr($d % 256); }
    my $n = substr($s, $$ir + 1, 1); $$ir += 2; return $n;
  }
  $$ir++; return $c;
}

sub parse_txt {
  my $s = shift // ''; my %kv; my $i = 0; my $L = length $s;
  while ($i < $L) {
    my $q = index($s, '"', $i); last if $q < 0; $i = $q + 1;
    my $key = '';
    while ($i < $L) { my $c = substr($s, $i, 1); last if $c eq '=' || $c eq '"'; $key .= $c; $i++; }
    last if $i >= $L;
    if (substr($s, $i, 1) eq '"') { $kv{$key} //= '' if $key =~ /^[\x21-\x7e]{1,32}$/; $i++; next; }
    $i++;
    my $val = ''; my $start = $i;
    if (exists $FIXED{$key} || $key eq 'omr') {
      my $n = $FIXED{$key};
      if ($key eq 'omr') { my $b = $i < $L ? dec_char($s, \$i) : ''; $val = $b; $n = int((ord($b) + 7) / 8); }
      for (1 .. $n) { last if $i >= $L; $val .= dec_char($s, \$i); }
      if ($i < $L && substr($s, $i, 1) ne '"') {
        my $e = index($s, '" "', $start); $e = index($s, '"', $start) if $e < 0; $e = $L if $e < 0;
        $val = substr($s, $start, $e - $start); $i = $e; $key .= '?';
      }
    } else {
      while ($i < $L) { my $c = substr($s, $i, 1); last if $c eq '"'; $val .= dec_char($s, \$i); }
    }
    $i++ if $i < $L && substr($s, $i, 1) eq '"';
    $kv{$key} //= $val if $key =~ /^[\x21-\x7e]{1,32}$/;
  }
  return \%kv;
}

sub emit {
  my ($R, $A) = @_;
  for my $n (sort keys %$R) {
    my ($h, $p, $kv) = @{$R->{$n}};
    print join("\t", 'R', flat($n), flat($h), flat($p),
      join(',', map { "$_=" . unpack('H*', $kv->{$_}) } sort keys %$kv)), "\n";
  }
  print "A\t$_\n" for sort keys %$A;
}

# ---- mode: parse `dns-sd -Z` output (macOS)
if ($mode eq 'zone2rec') {
  local $/; my $d = <STDIN> // '';
  my (%R, @starts);
  while ($d =~ /^(\S+?)\.(_[A-Za-z0-9-]+\._(?:udp|tcp))\s+SRV\s+\d+\s+\d+\s+(\d+)\s+(\S+)/mg) {
    my ($n, $port, $h) = (unesc($1), $3, unesc($4)); $h =~ s/\.$//;
    $R{$n} //= [$h, $port, {}];
  }
  while ($d =~ /^\S+\s+(?:PTR|SRV|TXT)\s/mg) { push @starts, $-[0]; }
  while ($d =~ /^(\S+?)\.(_[A-Za-z0-9-]+\._(?:udp|tcp))\s+TXT\s+/mg) {
    my $n = unesc($1); my $p = pos($d);
    my ($end) = grep { $_ > $p } @starts; $end //= length $d;
    my $kv = parse_txt(substr($d, $p, $end - $p));
    $R{$n} //= ['', '', {}];
    $R{$n}[2] = $kv unless %{ $R{$n}[2] };
  }
  emit(\%R, {}); exit 0;
}

# ---- mode: parse `dns-sd -G v6 HOST` output (macOS)
if ($mode eq 'g2addr') {
  my $h = shift(@ARGV) // ''; my %A;
  while (my $l = <STDIN>) {
    next unless $l =~ /\sAdd\s/;
    for my $f (split /\s+/, $l) {
      (my $a = $f) =~ s/%.*//;
      if ($a =~ /:.*:/ && expand6($a)) { $A{flat($h) . "\t" . lc($a) . "\t"} = 1; last; }
    }
  }
  emit({}, \%A); exit 0;
}

# ---- mode: parse `avahi-browse -rpt` output (Linux)
if ($mode eq 'avahi2rec') {
  my (%R, %A);
  while (my $l = <STDIN>) {
    chomp $l; next unless $l =~ /^=;/;
    my @f = split /;/, $l, 10; next unless @f >= 9;
    my ($if, $proto, $name, $host, $addr, $port, $txt) = @f[1, 2, 3, 6, 7, 8, 9];
    $name = unesc($name); $host = unesc($host); $host =~ s/\.$//;
    $R{$name} //= [$host, $port, parse_txt($txt // '')];
    if ($proto eq 'IPv6') {
      (my $a = lc $addr) =~ s/%.*//;
      $A{flat($host) . "\t$a\t" . (is_ll($a) ? flat($if) : '')} = 1 if expand6($a);
    }
  }
  emit(\%R, \%A); exit 0;
}

# ======================================================== analysis modes ==
my $W = shift(@ARGV) // die "no workdir\n";

sub rd {
  my $f = shift; open(my $fh, '<', "$W/$f") or return ();
  my @l = <$fh>; close $fh; chomp @l; return @l;
}
my %meta = map { /^([^=]+)=(.*)$/ ? ($1, $2) : () } rd('meta');
my $REDACT = $meta{redact} ? 1 : 0;

sub load_rec {
  my $f = shift; my (%R, %A);
  for my $l (rd($f)) {
    my @x = split /\t/, $l, -1;
    if ($x[0] eq 'R') {
      my %kv;
      for my $p (split /,/, $x[4] // '') {
        my ($k, $v) = split /=/, $p, 2; next unless defined $k && length $k;
        $kv{$k} = pack('H*', $v // '');
      }
      $R{$x[1]} = { host => $x[2], port => $x[3], kv => \%kv };
    } elsif ($x[0] eq 'A') {
      my $e = expand6($x[2]) or next;
      my $list = $A{$x[1]} ||= [];
      push @$list, { a => $e, if => $x[3] // '' } unless grep { $_->{a} eq $e } @$list;
    }
  }
  return (\%R, \%A);
}

my ($BR, $BRA)   = load_rec('meshcop.rec');
my ($MT, $MTA)   = load_rec('matter.rec');
my ($TREL)       = load_rec('trel.rec');
my ($SRPL)       = load_rec('srpl.rec');

my @routes  = map { [split /\t/, $_, -1] } rd('routes.tsv');   # dest gw iface flags/proto
my @routers = map { [split /\t/, $_, -1] } rd('routers.tsv');  # addr iface info
my @ifaddrs = map { [split /\t/, $_, -1] } rd('ifaddrs.tsv');  # iface addr
my %ping;  for (rd('ping.tsv'))  { my @x = split /\t/; my $e = expand6($x[0]) or next; $ping{$e} = { loss => $x[1], avg => $x[2], max => $x[3] }; }
my %aroute; for (rd('addrroute.tsv')) { my @x = split /\t/; my $e = expand6($x[0]) or next; $aroute{$e} = { if => $x[1], gw => $x[2] }; }
my @entry = map { [split /\t/, $_, -1] } rd('entry.tsv');      # label gw addr loss avg max

sub lan_if { my $i = shift // ''; return $i =~ /^(en|eth|eno|ens|enp|enx|wl|wlan|wlp|br|bond|bridge|vlan|lan|vmbr|end)/; }

# ---- border routers
my %brll;      # expanded link-local -> BR name
my %braddr;    # any expanded address -> BR name
my %omr;       # prefix string -> { P, by => [names] }
for my $n (keys %$BR) {
  my $h = $BR->{$n}{host};
  for my $x (@{ $BRA->{$h} || [] }) {
    $braddr{$x->{a}} = $n; $brll{$x->{a}} = $n if is_ll($x->{a});
  }
  my $o = $BR->{$n}{kv}{omr};
  if (defined $o && length $o >= 1) {
    my $len = ord(substr($o, 0, 1)); my $bytes = substr($o, 1);
    if ($len > 0 && $len <= 128 && length($bytes) >= int(($len + 7) / 8)) {
      my $full = substr($bytes . ("\0" x 16), 0, 16);
      my $e = join ':', map { sprintf '%04x', $_ } unpack('n8', $full);
      my $key = compress6($e) . "/$len";
      $omr{$key} ||= { P => { e => $e, len => $len }, by => [] };
      push @{ $omr{$key}{by} }, $n;
    }
  }
}

# ---- local interfaces
my %ifaddr; for (@ifaddrs) { my $e = expand6($_->[1]) or next; push @{ $ifaddr{$_->[0]} }, $e; }

# ---- routes
my @R6;
for my $r (@routes) {
  my ($dest, $gw, $if, $fl) = @$r;
  next unless defined $dest && ($dest =~ m{/} || $dest eq 'default');
  my $P = parse_prefix($dest);
  my $g = expand6($gw);
  push @R6, { dest => $dest, P => $P, gw => $gw, ge => $g, if => $if, fl => $fl };
}
my $defif = $meta{defif} // '';
my %mainrtr;
for my $r (@routes) {
  next unless ($r->[0] // '') eq 'default';
  my $g = expand6($r->[1]); $mainrtr{$g} = 1 if $g && is_ll($g) && lan_if($r->[2]);
}

# Thread-side prefixes: OMR from border routers, plus ULA prefixes routed via a
# link-local gateway, plus ULA prefixes on a non-LAN interface.
my @thread_pfx = map { $_->{P} } values %omr;
my %thread_if;
for my $r (@R6) {
  next unless $r->{P} && is_ula($r->{P}{e});
  if (!lan_if($r->{if}) && $r->{if} !~ /^lo/) {
    my $hit = grep { in_prefix($r->{P}{e}, $_->{P}) || in_prefix($_->{P}{e}, $r->{P}) } values %omr;
    if ($hit) { push @thread_pfx, $r->{P}; $thread_if{$r->{if}} = 1; }
  } elsif ($r->{ge} && is_ll($r->{ge}) && lan_if($r->{if})) { push @thread_pfx, $r->{P}; }
}
for my $if (keys %ifaddr) {
  next if lan_if($if);
  for my $e (@{ $ifaddr{$if} }) { $thread_if{$if} = 1 if grep { in_prefix($e, $_->{P}) } values %omr; }
}
my @lan_pfx = map { $_->{P} } grep { $_->{P} && is_ula($_->{P}{e}) && lan_if($_->{if}) && !($_->{ge} && is_ll($_->{ge})) } @R6;

sub classify {
  my $e = shift;
  return 'link-local' if is_ll($e);
  return 'thread' if grep { in_prefix($e, $_->{P}) } values %omr;
  return 'lan'    if grep { in_prefix($e, $_) } @lan_pfx;
  return 'thread?' if grep { in_prefix($e, $_) } @thread_pfx;
  return is_ula($e) ? 'private' : 'global';
}

# ---- matter devices
my %dev;   # host -> { fab => {cfid => node}, kv => {...} }
for my $inst (keys %$MT) {
  my $h = $MT->{$inst}{host}; next unless length $h;
  my $d = $dev{$h} ||= { fab => {}, kv => {} };
  if ($inst =~ /^([0-9A-Fa-f]{16})-([0-9A-Fa-f]{16})$/) { $d->{fab}{uc $1} = hex($2); }
  else { $d->{fab}{'?'} = $inst; }
  for my $k (qw(SII SAI SAT T ICD)) { $d->{kv}{$k} //= $MT->{$inst}{kv}{$k} if defined $MT->{$inst}{kv}{$k}; }
}

# ---- helper outputs used by the shell script
if ($mode eq 'pingtargets') {
  my %s;
  for my $h (keys %dev) { for my $x (@{ $MTA->{$h} || [] }) { $s{compress6($x->{a})} = 1 unless is_ll($x->{a}); } }
  print "$_\n" for sort keys %s; exit 0;
}
if ($mode eq 'entrytargets') {
  my %s;
  for my $h (keys %dev) { for my $x (@{ $MTA->{$h} || [] }) { my $c = classify($x->{a}); $s{compress6($x->{a})} = 1 if $c eq 'thread' || $c eq 'thread?'; } }
  print "$_\n" for sort keys %s; exit 0;
}
if ($mode eq 'gateways') {
  my $forced = shift(@ARGV) // '';
  my %seen; my @out;
  my %rif; for (@routers) { my $e = expand6($_->[0]) or next; $rif{$e} ||= $_->[1] if lan_if($_->[1]); }
  for my $n (sort keys %$BR) {
    my $h = $BR->{$n}{host};
    for my $x (@{ $BRA->{$h} || [] }) {
      next unless is_ll($x->{a}); next if $seen{$x->{a}}++;
      my $if = $forced || (lan_if($x->{if}) ? $x->{if} : '') || $rif{$x->{a}} || $defif;
      push @out, join("\t", flat($n), compress6($x->{a}), $if) if $if =~ /^[A-Za-z0-9_.-]+$/;
    }
  }
  if (!@out) {
    for my $r (@R6) {
      next unless $r->{P} && is_ula($r->{P}{e}) && $r->{ge} && is_ll($r->{ge}) && lan_if($r->{if});
      next if $seen{$r->{ge}}++;
      my $if = $forced || $r->{if};
      next unless $if =~ /^[A-Za-z0-9_.-]+$/;
      push @out, join("\t", 'router ' . compress6($r->{ge}), compress6($r->{ge}), $if);
    }
  }
  print "$_\n" for @out; exit 0;
}
exit 0 unless $mode eq 'report';

# ============================================================== report ====
my (%tok, %cnt);
sub T { my ($k, $v) = @_; return $v unless $REDACT; return $tok{$k}{$v} //= $k . (++$cnt{$k}); }
sub A {   # display an address
  my $e = expand6(shift) or return '?';
  return compress6($e) unless $REDACT;
  my @g = split /:/, $e;
  my $p = join(':', @g[0 .. 3]); my $iid = join(':', @g[4 .. 7]);
  my $pt = is_ll($e) ? 'fe80' : T('P', $p);
  return $pt . '::' . T('i', $iid);
}
sub PX {  # display a prefix
  my $P = shift; return '?' unless $P;
  return compress6($P->{e}) . "/$P->{len}" unless $REDACT;
  my @g = split /:/, $P->{e}; my $k = join(':', @g[0 .. 3]);
  return ($P->{len} == 64 ? T('P', $k) : T('Px', compress6($P->{e}) . "/$P->{len}")) . "::/$P->{len}";
}
sub BRN { return safe(T('br', shift)); }
sub HOST { return safe(T('host', shift)); }
sub DEVN { return safe(T('dev', shift)); }
sub FAB { return T('fabric', shift); }
sub hexs { return unpack('H*', shift // ''); }
sub ms { my $v = shift; return '-' unless defined $v && length $v; return $v >= 100 ? sprintf('%.0f ms', $v) : sprintf('%.1f ms', $v); }
sub gwname { my $g = shift; return '' unless $g; my $e = expand6($g) or return safe($g); return $brll{$e} ? 'border router ' . BRN($brll{$e}) : $mainrtr{$e} ? 'main router' : A($e); }

my (@warn, @note);
my $o = '';
sub out { $o .= join('', @_) . "\n"; }
sub hr { out(''); out('== ', @_); }

out("threadprobe $meta{version} report");
out("Generated: $meta{date}");
out("Host OS:   $meta{os}");
out("Options:   pings=$meta{count} browse=$meta{browse}s entry-test=$meta{entry} redacted=" . ($REDACT ? 'yes' : 'no'));

# ---- 1. border routers
hr('1. Thread border routers (from _meshcop._udp announcements)');
my (%by_xp, %nn, %leaders);
if (!%$BR) {
  out('  None found. Either there is no Thread border router on this LAN segment, or mDNS');
  out('  is not crossing from them to this computer (different VLAN, multicast filtering).');
  push @warn, 'No Thread border routers were announced on this LAN segment.';
}
for my $n (sort keys %$BR) {
  my $kv = $BR->{$n}{kv};
  my $xp = exists $kv->{xp} ? hexs($kv->{xp}) : '';
  my $pt = exists $kv->{pt} ? hexs($kv->{pt}) : '';
  push @{ $by_xp{$xp} }, $n; $nn{$kv->{nn}}++ if defined $kv->{nn};
  out('  ', BRN($n));
  out('    vendor/model : ', safe($kv->{vn} // '?'), ' / ', safe($kv->{mn} // '?'), '   Thread version: ', safe($kv->{tv} // '?'));
  out('    network      : ', defined $kv->{nn} ? safe(T('net', $kv->{nn})) : '?',
      '   ext PAN ID: ', length $xp ? T('xpan', $xp) : '?', '   partition: ', length $pt ? $pt : '?');
  if (exists $kv->{sb} && length $kv->{sb} == 4) {
    my $v = unpack('N', $kv->{sb});
    my @ifs = ('not initialised', 'initialised, inactive', 'active', '?');
    my @role = ('disabled/detached', 'child', 'router', 'leader');
    my $r = ($v >> 9) & 3;
    my ($maj, $min) = (($kv->{tv} // '') =~ /^(\d+)\.(\d+)/);
    my $has_role = $r || (defined $maj && ($maj > 1 || ($maj == 1 && $min >= 4)));
    out(sprintf('    state        : thread interface %s, role %s%s%s  (sb=0x%08x)',
      $ifs[($v >> 3) & 3], $has_role ? $role[$r] : 'not reported by this firmware', ($v >> 7) & 1 ? ', backbone router active' : '',
      ($v >> 8) & 1 ? ', primary backbone router' : '', $v));
    $leaders{$n} = 1 if $has_role && $r == 3;
    push @warn, 'Border router ' . BRN($n) . ' reports its Thread interface is not active.' if (($v >> 3) & 3) != 2;
    push @warn, 'Border router ' . BRN($n) . ' reports it is detached from the Thread network.' if (($v >> 3) & 3) == 2 && $has_role && $r == 0;
  }
  my ($oo) = grep { grep { $_ eq $n } @{ $omr{$_}{by} } } keys %omr;
  out('    device range : ', $oo ? PX($omr{$oo}{P}) . ' (off-mesh-routable prefix it advertises)' : '(not advertised in its announcement)');
  my @ad = map { A($_->{a}) } @{ $BRA->{ $BR->{$n}{host} } || [] };
  out('    host         : ', HOST($BR->{$n}{host}), '   addresses: ', @ad ? join(' ', @ad) : '(none resolved)');
  my @odd = grep { /\?$/ } keys %$kv;
  out('    note         : could not decode ', join(', ', map { (my $k = $_) =~ s/\?$//; $k } @odd), ' (unexpected length)') if @odd;
}
if (%$BR) {
  my @x = grep { length } keys %by_xp;
  if (@x > 1) { push @warn, scalar(@x) . ' different Thread networks (extended PAN IDs) are being announced. Devices on one cannot talk to devices on another.'; }
  if (keys %nn > 1) { push @warn, 'Border routers announce different network names: ' . join(', ', map { safe(T('net', $_)) } sort keys %nn) . '.'; }
  for my $xp (@x) {
    my %pts;
    for my $n (@{ $by_xp{$xp} }) { my $p = $BR->{$n}{kv}{pt}; $pts{hexs($p)}{$n} = 1 if defined $p && length $p == 4; }
    my @p = sort keys %pts;
    next if @p < 2;
    # Some firmware publishes the partition ID byte-reversed; don't call that a split.
    my %canon; for my $p (@p) { my $r = join '', reverse($p =~ /(..)/g); my $c = $p lt $r ? $p : $r; $canon{$c}{$p} = 1; }
    if (keys %canon == 1) {
      push @note, 'Border routers publish the same partition ID in different byte orders (' . join(' vs ', @p) . '). That is a firmware quirk, not a split network.';
    } else {
      push @warn, 'The Thread network ' . T('xpan', $xp) . ' is split into ' . scalar(keys %canon) . ' partitions (' . join(', ', @p) . '). Devices in different partitions cannot reach each other.';
    }
  }
  if (keys %leaders > 1) { push @warn, 'More than one border router claims to be the Thread leader (' . join(', ', map { BRN($_) } sort keys %leaders) . '). There should be exactly one per partition.'; }
  my @omrs = keys %omr;
  if (@omrs > 1) { push @warn, 'More than one off-mesh-routable prefix is advertised (' . join(', ', map { PX($omr{$_}{P}) } @omrs) . '). Devices may get addresses that only some routes reach.'; }
  if (!@omrs) { push @note, 'No border router included its off-mesh-routable prefix (omr) in its announcement; Thread addresses are inferred from routes instead.'; }
}

# ---- 2. TREL / SRP replication
hr('2. Border router peering over the LAN');
my @trel = sort keys %$TREL; my @srpl = sort keys %$SRPL;
out('  Thread-over-LAN links (TREL, _trel._udp): ', scalar(@trel), ' announced');
out('  SRP replication peers (_srpl-tls._tcp):    ', scalar(@srpl), @srpl ? ' (' . join(', ', map { BRN($_) } @srpl) . ')' : '');

# ---- 3. routes
hr('3. IPv6 routes this computer has towards private (ULA) prefixes');
my %omr_seen_route;
for my $r (sort { $a->{dest} cmp $b->{dest} } @R6) {
  next unless $r->{P} && is_ula($r->{P}{e}) && $r->{P}{len} < 128;
  my $what;
  my $is_omr = grep { $_->{P}{e} eq $r->{P}{e} && $_->{P}{len} == $r->{P}{len} } values %omr;
  if ($thread_if{$r->{if}}) {
    $what = 'this computer\'s own Thread interface' . ($is_omr ? '  [Thread device range]' : '');
    $omr_seen_route{ $r->{P}{e} } = 1;
  } elsif ($r->{ge} && is_ll($r->{ge}) && lan_if($r->{if})) {
    $what = 'routed via ' . gwname($r->{ge}) . ($is_omr ? '  [Thread device range]' : (%omr ? '  [NOT an advertised Thread device range]' : ''));
    my $known = $brll{$r->{ge}};
    if (%omr && !$is_omr && !$known) {
      push @warn, 'Route to ' . PX($r->{P}) . ' via ' . A($r->{ge}) . ': that router is not a current border router and the range is not an advertised Thread device range (likely left over from a border router that restarted). Devices holding addresses in it will be unreachable.';
    } elsif (%omr && !$is_omr) {
      push @warn, 'Border router ' . BRN($known) . ' routes ' . PX($r->{P}) . ', which is not an advertised Thread device range. Devices holding addresses in it may be unreachable.';
    } elsif (%brll && !$known) {
      push @warn, 'Route to the Thread device range ' . PX($r->{P}) . ' goes via ' . A($r->{ge}) . ', which is not the current address of any announced border router (possibly left over from a border router that restarted).';
    }
    $omr_seen_route{ $r->{P}{e} } = 1;
  } elsif (lan_if($r->{if})) {
    $what = 'on-link on the LAN';
  } else {
    $what = 'on interface ' . safe($r->{if}) . ' (VPN or other tunnel; not Thread)';
  }
  out(sprintf('  %-26s %-8s %s', PX($r->{P}), safe($r->{if}), $what));
}
for my $k (keys %omr) {
  next if $omr_seen_route{ $omr{$k}{P}{e} };
  push @warn, 'This computer has no route to the Thread device range ' . PX($omr{$k}{P}) . '. Border routers advertise it, but the route advertisement is not reaching (or not accepted by) this computer.';
}

# ---- 4. routers
hr('4. IPv6 routers heard on the LAN');
my %rseen;
for my $r (@routers) {
  my $e = expand6($r->[0]) or next; next unless lan_if($r->[1]);
  next if $rseen{$e}{ $r->[1] }++;
}
for my $e (sort keys %rseen) {
  my $label = $brll{$e} ? 'border router ' . BRN($brll{$e}) : $mainrtr{$e} ? 'main router (default route)' : 'not a current border router or the main router';
  my ($info) = map { $_->[2] } grep { (expand6($_->[0]) // '') eq $e } @routers;
  out(sprintf('  %-28s %-8s %s', A($e), join(',', sort keys %{ $rseen{$e} }), $label));
  out('      ', safe($info)) if defined $info && length $info;
}
out('  (none)') unless %rseen;
my @stale = grep { !$brll{$_} && !$mainrtr{$_} } keys %rseen;
if (%brll && @stale) {
  push @note, scalar(@stale) . ' IPv6 router' . (@stale > 1 ? 's' : '') . ' on the LAN ' . (@stale > 1 ? 'are' : 'is') . ' neither a current border router nor the main router. Usually these are old addresses of border routers that restarted; this computer forgets them when their advertised lifetime runs out. Until then, traffic routed through them can be lost.';
}

# ---- 5. local Thread interface
hr('5. This computer on the Thread mesh');
if (%thread_if) {
  for my $if (sort keys %thread_if) {
    out('  Interface ', safe($if), ' carries Thread routes; this computer is itself attached to the mesh.');
    for my $e (@{ $ifaddr{$if} || [] }) {
      my $extra = '';
      if ($e =~ /:0000:00ff:fe00:([0-9a-f]{4})$/) {
        my $r16 = hex $1; my $rid = $r16 >> 10; my $cid = $r16 & 0x1ff;
        $extra = $cid ? sprintf('  <- routing locator 0x%04x: CHILD (end device) of router %d', $r16, $rid)
                      : sprintf('  <- routing locator 0x%04x: ROUTER %d', $r16, $rid);
      }
      out('    ', A($e), $extra);
    }
  }
  push @note, 'This computer is attached to the Thread mesh through its own interface. Traffic it sends to Thread devices goes over that interface, not via a border router on the LAN; if it attached as a child, replies can wait for its parent to hand them over.';
} else {
  out('  Not attached. Traffic to Thread devices goes via border routers on the LAN.');
}

# ---- 6. matter devices
hr('6. Matter devices announced on the LAN (_matter._tcp)');
my %fab_count; my %fab_self;
for my $h (keys %dev) { for my $f (grep { $_ ne '?' } keys %{ $dev{$h}{fab} }) { $fab_count{$f}++; $fab_self{$f} = 1 if $dev{$h}{fab}{$f} eq '112233'; } }
if (!%dev) {
  out('  None found.');
  push @warn, 'No Matter devices were announced. If you have Matter devices, mDNS may not be reaching this computer.';
}
my (@traps, @slow, @dead, @sleepy, @outside, @many);
my $self_child = grep { my $if = $_; grep { /:0000:00ff:fe00:[0-9a-f]{4}$/ && (hex(substr($_, -4)) & 0x1ff) } @{ $ifaddr{$if} || [] } } keys %thread_if;
for my $h (sort keys %dev) {
  my $d = $dev{$h};
  my @addr = grep { !is_ll($_->{a}) } @{ $MTA->{$h} || [] };
  my ($is_br) = map { $braddr{$_->{a}} } grep { $braddr{$_->{a}} } @{ $MTA->{$h} || [] };
  # Matter hostnames are derived from the device's MAC: 16 hex digits (64-bit) for
  # Thread, 12 for Wi-Fi/Ethernet (some bridges pad a 48-bit MAC with 0000).
  my $thread_name = ($h =~ /^([0-9A-Fa-f]{16})(?:\.|$)/ && $1 !~ /0000$/) ? 1 : 0;
  my $has_thread_addr = grep { %omr ? classify($_->{a}) eq 'thread' : classify($_->{a}) =~ /^thread/ } @addr;
  my $kind = ($has_thread_addr || grep { classify($_->{a}) eq 'thread?' } @addr) ? 'Thread device'
           : $is_br ? 'runs on border router ' . BRN($is_br)
           : grep({ classify($_->{a}) eq 'lan' } @addr) ? 'LAN device or bridge'
           : $thread_name ? 'Thread device, by its name'
           : 'LAN device';
  my $sii = $d->{kv}{SII}; my $sleepy = defined $sii && $sii =~ /^\d+$/ && $sii >= 4000;
  $kind .= sprintf(', probably sleepy: idle retry interval %.1f s', $sii / 1000) if $sleepy;
  out('  ', DEVN($h), "   ($kind)");
  out('    controllers  : ', join('  ', map { $_ eq '?' ? 'unrecognised instance ' . safe(T('inst', $d->{fab}{$_})) : FAB($_) . '=node ' . $d->{fab}{$_} } sort keys %{ $d->{fab} }), '   (', scalar(keys %{ $d->{fab} }), ')');
  my $kvs = join(' ', map { "$_=" . safe($d->{kv}{$_}) } grep { defined $d->{kv}{$_} } qw(SII SAI SAT T ICD));
  out('    advertises   : ', $kvs) if length $kvs;
  if (!@addr) { out('    addresses    : NONE resolved'); push @dead, $h; next; }
  my $ok = 0;
  for my $x (@addr) {
    my $c = classify($x->{a}); my $p = $ping{$x->{a}}; my $rt = $aroute{$x->{a}};
    my $via = $rt ? safe($rt->{if}) . ($rt->{gw} && expand6($rt->{gw}) ? ' via ' . gwname($rt->{gw}) : '') : '';
    my $res = $p ? sprintf('loss %-6s avg %-9s max %-9s', $p->{loss}, ms($p->{avg}), ms($p->{max})) : '(not tested)';
    $via = "route: $via" if length $via;
    out(sprintf('    %-38s %-8s %-38s %s', A($x->{a}), $c, $res, $via));
    if ($p) {
      if ($p->{loss} =~ /^100/) { push @traps, [$h, $x->{a}]; }
      else {
        $ok++;
        if (length $p->{avg} && $p->{avg} > 1000) {
          if ($sleepy) { push @sleepy, [$h, $x->{a}, $p->{avg}, $sii]; }
          else { push @slow, [$h, $x->{a}, $p->{avg}, ($rt && $thread_if{$rt->{if}} && $self_child) ? 1 : 0]; }
        }
      }
    }
  }
  if (%omr && ($thread_name || $has_thread_addr) && !$is_br) {
    my @out = grep { my $c = classify($_->{a}); $c ne 'thread' && $c ne 'lan' } @addr;
    push @outside, [$h, \@out, $has_thread_addr] if @out;
  }
  push @dead, $h if %ping && !$ok && @addr;
  push @many, $h if keys %{ $d->{fab} } >= 5;
}
out('');
out('  Controllers (fabrics) seen:');
for my $f (sort { $fab_count{$b} <=> $fab_count{$a} || $a cmp $b } keys %fab_count) {
  out(sprintf('    %-20s %3d device(s)%s', FAB($f), $fab_count{$f}, $fab_self{$f} ? '   (includes the controller itself, announcing node 112233, a common default in open-source controllers)' : ''));
}
if (@many) {
  push @note, scalar(@many) . ' device' . (@many > 1 ? 's belong' : ' belongs') . ' to 5 or more controllers (' . join(', ', map { DEVN($_) } @many) . '). Many devices only support 5, and each controller keeps its own sessions with the device; remove controllers you no longer use.';
}
my %outh = map { $_->[0] => 1 } grep { !$_->[2] } @outside;
@dead = grep { !$outh{$_} } @dead;
my %deadh = map { $_ => 1 } @dead, keys %outh;
my %outa = map { my $o = $_; map { ($o->[0] . ' ' . $_->{a}) => 1 } @{ $o->[1] } } @outside;
for (@traps) {
  my ($h, $a) = @$_;
  next if $deadh{$h} || $outa{"$h $a"};
  my $other = grep { $_->{a} ne $a && !is_ll($_->{a}) && $ping{$_->{a}} && $ping{$_->{a}}{loss} !~ /^100/ } @{ $MTA->{$h} || [] };
  push @warn, DEVN($h) . ' announces ' . A($a) . ', which does not answer.' . ($other ? ' It also announces a working address, so controllers that try this one first will time out and retry.' : ' Controllers that look this device up will time out.');
}
for (@slow) {
  push @warn, DEVN($_->[0]) . ' answers, but slowly (average ' . ms($_->[2]) . ' on ' . A($_->[1]) . ').'
    . ($_->[3] ? ' Measured through this computer\'s own Thread interface as a child, which adds delay; run with --entry-test to measure through each border router instead.' : '');
}
for (@sleepy) {
  push @note, DEVN($_->[0]) . sprintf(' answers slowly (average %s), but it asks controllers to wait %.1f s before retrying while idle, which suggests a sleepy (battery or low-power) device. Slow replies are expected.', ms($_->[2]), $_->[3] / 1000);
}
for (@outside) {
  my ($h, $out, $alsook) = @$_;
  my $deadn = grep { $ping{$_->{a}} && $ping{$_->{a}}{loss} =~ /^100/ } @$out;
  push @warn, DEVN($h) . ' announces ' . join(', ', map { A($_->{a}) } @$out) . ', outside the advertised Thread device range'
    . ($deadn ? ' (' . ($deadn == @$out ? (@$out > 1 ? 'none answer' : 'it does not answer') : 'some do not answer') . ')' : '')
    . ($alsook ? '. It also has a working address, so controllers that try the bad one first will time out and retry.'
               : ', and no address inside it. Controllers that look it up get an address the Thread network does not route, and time out.')
    . ' Power-cycling the device usually makes it re-register; if the address comes back, a border router is still offering that range.';
}
for my $h (@dead) {
  my @ad = map { A($_->{a}) } grep { !is_ll($_->{a}) } @{ $MTA->{$h} || [] };
  if (@ad) { push @warn, DEVN($h) . ' has no reachable address (announces ' . join(', ', @ad) . ', none answer). Controllers that look it up will time out.'; }
  else     { push @note, DEVN($h) . ' was announced, but no IPv6 address for it could be resolved from this computer.'; }
}

# ---- 7. entry test
if (@entry) {
  hr('7. Entry-point test: each Thread address reached through each border router');
  my (%by, @order, %addr_host);
  for my $h (keys %dev) { for my $x (@{ $MTA->{$h} || [] }) { $addr_host{$x->{a}} = $h; } }
  for my $r (@entry) {
    my ($label, $gw, $a, $loss, $avg, $max) = @$r;
    push @order, $label unless $by{$label};
    push @{ $by{$label} }, [$a, $loss, $avg, $max, $gw];
  }
  my %score;
  for my $l (@order) {
    my $gw = $by{$l}[0][4];
    my $lab = (expand6($gw) && $brll{ expand6($gw) }) ? BRN($brll{ expand6($gw) }) : A($gw);
    out('  via ', $lab);
    my ($sum, $n, $lost) = (0, 0, 0);
    for my $x (@{ $by{$l} }) {
      my $e = expand6($x->[0]);
      out(sprintf('    %-24s %-38s loss %-6s avg %-9s max %s', DEVN($addr_host{$e} // '?'), A($e), $x->[1], ms($x->[2]), ms($x->[3])));
      if ($x->[1] =~ /^100/) { $lost++; } elsif (length $x->[2]) { $sum += $x->[2]; $n++; }
    }
    $score{$lab} = [$n ? $sum / $n : 0, $lost];
  }
  if (keys %score > 1) {
    my @best = sort { $score{$a}[1] <=> $score{$b}[1] || $score{$a}[0] <=> $score{$b}[0] || $a cmp $b } keys %score;
    my ($b0, $bN) = ($score{$best[0]}, $score{$best[-1]});
    if ($b0->[1] != $bN->[1] || abs($b0->[0] - $bN->[0]) >= 20) {
      push @note, sprintf('Entry-point test: best path in was %s (average %.0f ms, %d unreachable); worst was %s (average %.0f ms, %d unreachable).',
        $best[0], $b0->[0], $b0->[1], $best[-1], $bN->[0], $bN->[1]);
    } else {
      push @note, 'Entry-point test: all border routers gave similar results, so the way into the mesh is not the problem.';
    }
  }
}

# ---- summary
hr('Summary');
if (@warn) { out('  Problems found:'); out('    - ', $_) for @warn; }
else       { out('  No problems detected.'); }
if (@note) { out(''); out('  Notes:'); out('    - ', $_) for @note; }
out('');
out('  Tip: run this while the problem is happening and again when everything works, then compare.');

# ---- final redaction pass: catch any address or hardware ID that slipped through
if ($REDACT) {
  $o =~ s{(?<![0-9A-Za-z:])([0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7})(?![0-9A-Za-z:])}{ my $m = $1; expand6($m) ? A($m) : $m }ge;
  $o =~ s{(?<![0-9A-Fa-f:])([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})(?![0-9A-Fa-f:])}{T('mac', lc $1)}ge;
  $o =~ s{(?<![0-9A-Za-z])([0-9A-Fa-f]{12}|[0-9A-Fa-f]{16})(?![0-9A-Za-z])}{ my $m = $1; $m =~ /[A-Fa-f]/ && $m =~ /\d/ ? T('id', uc $m) : $m }ge;
}
print $o;
PERL

# -------------------------------------------------------------- utilities --

# Run a command for a fixed time, then stop it (dns-sd never exits on its own).
# Wait for background jobs after every MAXJOBS starts, so large networks
# don't get hundreds of pings at once (bash 3.2 has no `wait -n`).
MAXJOBS=16
throttle() { [ $(( $1 % MAXJOBS )) -eq 0 ] && wait; }

run_for() { local secs=$1; shift; "$@" </dev/null & local p=$!; sleep "$secs"; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; }

ping_summary() {   # addr count -> "loss\tavg\tmax"
  $PING -c "$2" "$1" </dev/null 2>&1 | awk '
    /packet loss/ { for (i = 1; i <= NF; i++) if ($i ~ /%/) { l = $i; sub(/,$/, "", l) } }
    /min\/avg\/max/ { split($0, a, "="); split(a[2], b, "/"); avg = b[2]; max = b[3]; gsub(/[^0-9.]/, "", avg); gsub(/[^0-9.]/, "", max) }
    END { if (l == "") l = "100%"; printf "%s\t%s\t%s\n", l, avg, max }'
}

# Adds a temporary host route. Fails (and changes nothing) if a host route to
# that address already exists, so routes the user set up are never touched.
route_add() {   # addr gw iface
  if [ "$PLATFORM" = mac ]; then
    $SUDO route -n add -inet6 -host "$1" "$2%$3" >/dev/null 2>&1
  else
    $SUDO ip -6 route add "$1/128" via "$2" dev "$3" >/dev/null 2>&1
  fi
}
route_del() {
  if [ "$PLATFORM" = mac ]; then $SUDO route -n delete -inet6 -host "$1" >/dev/null 2>&1
  else $SUDO ip -6 route del "$1/128" >/dev/null 2>&1; fi
}
route_of() {    # addr -> "iface\tgw"
  if [ "$PLATFORM" = mac ]; then
    route -n get -inet6 "$1" 2>/dev/null | awk '/interface:/{i=$2} /gateway:/{g=$2} END{sub(/%.*/,"",g); printf "%s\t%s\n", i, g}'
  else
    ip -6 route get "$1" 2>/dev/null | awk '{for(k=1;k<NF;k++){if($k=="dev")i=$(k+1); if($k=="via")g=$(k+1)}} END{printf "%s\t%s\n", i, g}'
  fi
}

# Collect one mDNS service type into a normalised record file.
mdns_collect() {   # service outfile resolve_addresses(0/1)
  local svc=$1 out=$2 res=$3
  if [ "$PLATFORM" = mac ]; then
    run_for "$BROWSE" dns-sd -Z "$svc" local. > "$W/$out.raw"
    perl "$W/helper.pl" zone2rec < "$W/$out.raw" > "$W/$out"
    if [ "$res" = 1 ]; then
      local n=0 h
      awk -F'\t' '$1=="R" && $3!="" {print $3}' "$W/$out" | sort -u > "$W/$out.hosts"
      while IFS= read -r h; do
        case "$h" in -*|'') continue;; esac   # never let announced names be read as options
        n=$((n + 1)); printf '%s\n' "$h" > "$W/$out.h$n"
        ( run_for 3 dns-sd -G v6 "$h" > "$W/$out.g$n" ) &
      done < "$W/$out.hosts"
      wait
      local i=1
      while [ "$i" -le "$n" ]; do
        perl "$W/helper.pl" g2addr "$(cat "$W/$out.h$i")" < "$W/$out.g$i" >> "$W/$out"
        i=$((i + 1))
      done
    fi
  else
    if command -v timeout >/dev/null 2>&1; then
      timeout $((BROWSE + 15)) avahi-browse -rpt "$svc" > "$W/$out.raw" 2> "$W/$out.err"
    else
      avahi-browse -rpt "$svc" > "$W/$out.raw" 2> "$W/$out.err"
    fi
    grep -qi 'fail' "$W/$out.err" 2>/dev/null && log "warning: avahi-browse reported an error for $svc: $(head -1 "$W/$out.err" | tr -d '\000-\037')"
    perl "$W/helper.pl" avahi2rec < "$W/$out.raw" > "$W/$out"
  fi
}

# ------------------------------------------------------------------ main --

if [ "$ENTRY" = 1 ] && [ "$(id -u)" != 0 ]; then
  need sudo "--entry-test needs root."
  log "The entry-point test adds temporary routes and needs administrator rights."
  sudo -v || die "sudo failed"
  SUDO="sudo"
  ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 30; done ) &
  KEEPALIVE=$!
fi

TS=$(date +%Y%m%d-%H%M%S)
if [ -z "$OUT" ]; then
  if [ -z "$REPORTDIR" ]; then
    case "$0" in */*) SCRIPTDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd);; *) SCRIPTDIR=$(pwd);; esac
    REPORTDIR="$SCRIPTDIR/reports"
    if ! mkdir -p "$REPORTDIR" 2>/dev/null || [ ! -w "$REPORTDIR" ]; then REPORTDIR="./reports"; fi
  fi
  mkdir -p "$REPORTDIR" 2>/dev/null || die "can't create report folder $REPORTDIR"
  OUT="$REPORTDIR/threadprobe-$TS$([ "$REDACT" = 1 ] && echo -redacted).txt"
else
  mkdir -p "$(dirname "$OUT")" 2>/dev/null
fi

if [ "$PLATFORM" = mac ]; then OSDESC="macOS $(sw_vers -productVersion 2>/dev/null)"
else OSDESC="Linux $(uname -r)"; fi
{
  echo "version=$VERSION"; echo "date=$(date)"; echo "os=$OSDESC"
  echo "count=$COUNT"; echo "browse=$BROWSE"; echo "entry=$ENTRY"; echo "redact=$REDACT"
} > "$W/meta"

log "threadprobe $VERSION - collecting (about $((BROWSE + 5 + (NOPING == 0 ? COUNT + 2 : 0))) seconds$([ "$ENTRY" = 1 ] && echo ', plus the entry-point test'))..."

# Routes, routers and local addresses
if [ "$PLATFORM" = mac ]; then
  netstat -rn -f inet6 2>/dev/null | awk '($1 ~ /:/ || $1 == "default") && NF >= 4 {print $1"\t"$2"\t"$4"\t"$3}' > "$W/routes.tsv"
  ndp -rn 2>/dev/null | awk '$1 ~ /^fe80/ {split($1, x, "%"); a = x[1]; i = x[2]; $1 = ""; sub(/^ /, ""); print a"\t"i"\t"$0}' > "$W/routers.tsv"
  ifconfig 2>/dev/null | awk '/^[A-Za-z0-9]/ {i = $1; sub(/:$/, "", i)} $1 == "inet6" {a = $2; sub(/%.*/, "", a); print i"\t"a}' > "$W/ifaddrs.tsv"
  DEFIF=$(route -n get -inet6 default 2>/dev/null | awk '/interface:/{print $2}')
  [ -n "$DEFIF" ] || DEFIF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
else
  ip -6 route show 2>/dev/null | awk '{p = $1; g = "link"; d = ""; pr = ""; for (k = 2; k < NF; k++) { if ($k == "via") g = $(k+1); if ($k == "dev") d = $(k+1); if ($k == "proto") pr = $(k+1) } print p"\t"g"\t"d"\t"pr}' > "$W/routes.tsv"
  ip -6 neigh show 2>/dev/null | awk '/ router/ {d = ""; for (k = 2; k < NF; k++) if ($k == "dev") d = $(k+1); a = $1; $1 = ""; sub(/^ /, ""); print a"\t"d"\t"$0}' > "$W/routers.tsv"
  ip -6 -o addr show 2>/dev/null | awk '{a = $4; sub(/\/.*/, "", a); print $2"\t"a}' > "$W/ifaddrs.tsv"
  DEFIF=$(ip -6 route show default 2>/dev/null | awk '{for (k = 1; k < NF; k++) if ($k == "dev") {print $(k+1); exit}}')
  [ -n "$DEFIF" ] || DEFIF=$(ip route show default 2>/dev/null | awk '{for (k = 1; k < NF; k++) if ($k == "dev") {print $(k+1); exit}}')
fi
echo "defif=$DEFIF" >> "$W/meta"

# mDNS: border routers and Matter devices (with addresses), plus peering services
mdns_collect _meshcop._udp   meshcop.rec 1 &
mdns_collect _matter._tcp    matter.rec  1 &
mdns_collect _trel._udp      trel.rec    0 &
mdns_collect _srpl-tls._tcp  srpl.rec    0 &
wait

: > "$W/ping.tsv"; : > "$W/addrroute.tsv"; : > "$W/entry.tsv"

if [ "$NOPING" = 0 ]; then
  perl "$W/helper.pl" pingtargets "$W" > "$W/targets"
  log "Pinging $(wc -l < "$W/targets" | tr -d ' ') addresses ($COUNT pings each)..."
  n=0
  while IFS= read -r a; do
    n=$((n + 1))
    ( printf '%s\t%s\n' "$a" "$(ping_summary "$a" "$COUNT")" > "$W/p.$n" ) &
    printf '%s\t%s\n' "$a" "$(route_of "$a")" >> "$W/addrroute.tsv"
    throttle "$n"
  done < "$W/targets"
  wait
  cat "$W"/p.* > "$W/ping.tsv" 2>/dev/null
fi

if [ "$ENTRY" = 1 ]; then
  perl "$W/helper.pl" entrytargets "$W" > "$W/etargets"
  perl "$W/helper.pl" gateways "$W" "$IFACE" > "$W/gateways"
  if [ ! -s "$W/etargets" ] || [ ! -s "$W/gateways" ]; then
    log "Entry-point test skipped: no Thread device addresses or border router link-local addresses found."
  else
    log "Entry-point test: $(wc -l < "$W/gateways" | tr -d ' ') border routers x $(wc -l < "$W/etargets" | tr -d ' ') addresses..."
    while IFS="$(printf '\t')" read -r label gw gif; do
      : > "$W/eok"
      while IFS= read -r a; do
        if route_add "$a" "$gw" "$gif"; then
          printf '%s\n' "$a" >> "$ADDED"; printf '%s\n' "$a" >> "$W/eok"
        else
          printf '%s\t%s\t%s\troute-failed\t\t\n' "$label" "$gw" "$a" >> "$W/entry.tsv"
        fi
      done < "$W/etargets"
      n=0
      while IFS= read -r a; do
        n=$((n + 1))
        ( printf '%s\t%s\t%s\t%s\n' "$label" "$gw" "$a" "$(ping_summary "$a" "$COUNT")" > "$W/e.$n" ) &
        throttle "$n"
      done < "$W/eok"
      wait
      cat "$W"/e.* >> "$W/entry.tsv" 2>/dev/null; rm -f "$W"/e.*
      while IFS= read -r a; do route_del "$a"; done < "$W/eok"
      : > "$ADDED"
    done < "$W/gateways"
  fi
fi

perl "$W/helper.pl" report "$W" > "$W/report.txt" || die "report generation failed"
cp "$W/report.txt" "$OUT" || die "can't write $OUT"
[ "$QUIET" = 1 ] || cat "$W/report.txt"
log ""
log "Report saved to $OUT"
