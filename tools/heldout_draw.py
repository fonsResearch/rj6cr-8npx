#!/usr/bin/env python3
"""Held-out protocol draw for the v3 design. Standard library only.

Purpose: choose the protocols that are attempted only after the chip is frozen, so that
nobody working on the design (person or tool) can know them beforehand, and so that the
choice can be audited afterwards.

  python3 heldout_draw.py seal            # now: creates a secret salt, prints its commitment
  python3 heldout_draw.py draw            # after the printed pulse time: draws, prints one hash
  python3 heldout_draw.py verify FILE     # at reveal: recomputes everything from FILE

Scheme
  pool   = decoders of the sigrok catalogue (libsigrokdecode 71f4514430) whose input is
           raw logic (68), minus the protocols already planned (10), minus pure
           measurement utilities (7): 51 names, fixed in this file before any draw.
  seed   = outputValue of the first NIST randomness-beacon pulse at or after the pulse time
           fixed by `seal` (a time in the future when the salt is committed).
  draw   = the N names with the smallest sha256(seed ":" salt ":" name).
  sealed = sha256 of the result file; only that hash is printed and committed.
The salt keeps the draw secret although beacon and pool are public; committing the salt
before the pulse exists keeps the person running this from re-rolling.
Keep the output directory out of every folder shared with a design session.
"""
import argparse, datetime, hashlib, json, os, secrets, sys, time, urllib.error, urllib.request

CATALOGUE = "sigrokproject/libsigrokdecode@71f451443029322d57376214c330b518efd84f88"
PLANNED = ['uart', 'spi', 'i2c', 'can', 'usb_signalling', 'onewire_link', 'rgb_led_ws281x', 'jtag', 'swd', 'ps2']
UTILITIES = ['counter', 'graycode', 'guess_bitrate', 'jitter', 'numbers_and_state', 'timing', 'signature']
LOGIC_INPUT = ['ac97', 'am230x', 'aud', 'avr_pdi', 'caliper', 'can', 'cec', 'cjtag', 'counter', 'dali', 'dcf77', 'dsi', 'em4100', 'em4305', 'flexray', 'graycode', 'guess_bitrate', 'i2c', 'i2s', 'ieee488', 'ir_irmp', 'ir_nec', 'ir_rc5', 'ir_rc6', 'ir_sirc', 'jitter', 'jtag', 'lfast', 'lpc', 'maple_bus', 'mcs48', 'mdio', 'microwire', 'miller', 'morse', 'numbers_and_state', 'onewire_link', 'ook', 'parallel', 'pjdl', 'ps2', 'pwm', 'qi', 'rc_encode', 'rgb_led_ws281x', 'sae_j1850_vpw', 'sda2506', 'sdcard_sd', 'sdq', 'seven_segment', 'signature', 'sle44xx', 'spdif', 'spi', 'st7735', 'stepper_motor', 'swd', 'swim', 't55xx', 'tdm_audio', 'timing', 'tlc5620', 'uart', 'usb_power_delivery', 'usb_signalling', 'wiegand', 'xy2-100', 'z80']
POOL = sorted(n for n in LOGIC_INPUT if n not in PLANNED and n not in UTILITIES)
BEACON = "https://beacon.nist.gov/beacon/2.0"

def sha(s):
    return hashlib.sha256(s.encode() if isinstance(s, str) else s).hexdigest()

def get(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.loads(r.read())

def pulse_at_or_after(ms):
    try:
        p = get(f"{BEACON}/pulse/time/{ms}")["pulse"]
    except urllib.error.HTTPError as e:
        if e.code == 404:
            sys.exit("The beacon has not emitted that pulse yet. Run `draw` again after the pulse time.")
        raise
    t = datetime.datetime.strptime(p["timeStamp"], "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=datetime.timezone.utc)
    if int(t.timestamp() * 1000) < ms:
        sys.exit(f"Beacon returned an earlier pulse ({p['timeStamp']}); not using it.")
    return p

def pick(seed, salt, n):
    return sorted(POOL, key=lambda name: sha(f"{seed}:{salt}:{name}"))[:n]

def iso(ms):
    return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def out_dir(a):
    # Only a plain folder directly under the home directory, outside any git work tree:
    # project folders, which design sessions can read, are never that.
    d = os.path.realpath(os.path.expanduser(a.dir))
    home = os.path.realpath(os.path.expanduser("~"))
    in_git = any(os.path.exists(os.path.join(p, ".git")) for p in (d, os.path.dirname(d)))
    if os.path.dirname(d) != home or os.path.basename(d).startswith(".") or in_git:
        sys.exit(f"Refusing to use {d}: choose a new folder directly under {home}, not a project folder.")
    return d

def cmd_seal(a):
    d = out_dir(a)
    os.makedirs(d, exist_ok=True)
    f = os.path.join(d, "seal_state.json")
    if os.path.exists(f):
        sys.exit(f"{f} exists; a seal was already made. Remove it by hand only if nothing was committed.")
    salt = secrets.token_hex(32)
    ms = (int(time.time()) // 60 + 1 + a.delay_min) * 60000
    json.dump({"salt": salt, "pulse_time_ms": ms, "n": a.n}, open(f, "w"))
    os.chmod(f, 0o600)
    print("salt_commitment =", sha("v3-heldout-salt:" + salt))
    print("pulse_time      =", iso(ms))
    print("pool_sha256     =", sha(",".join(POOL)), f"({len(POOL)} names)")
    print("Give these three lines to the design session; they are committed before the pulse time.")

def cmd_draw(a):
    d = out_dir(a)
    st = json.load(open(os.path.join(d, "seal_state.json")))
    out = os.path.join(d, "heldout_list.json")
    if os.path.exists(out):
        sys.exit(f"{out} exists; the draw was already made. list_sha256 = {sha(open(out, 'rb').read())}")
    p = pulse_at_or_after(st["pulse_time_ms"])
    rec = {"catalogue": CATALOGUE, "pool": POOL, "salt": st["salt"], "n": st["n"],
           "pulse_time_ms": st["pulse_time_ms"], "beacon_chain": p["chainIndex"], "beacon_pulse": p["pulseIndex"],
           "beacon_time": p["timeStamp"], "beacon_output": p["outputValue"],
           "heldout": pick(p["outputValue"], st["salt"], st["n"])}
    open(out, "w").write(json.dumps(rec, sort_keys=True, indent=1) + "\n")
    os.chmod(out, 0o600)
    print("list_sha256  =", sha(open(out, "rb").read()))
    print("beacon_pulse =", p["chainIndex"], p["pulseIndex"], p["timeStamp"])
    print("The list is in the output directory. Do not open it in, or paste it into, a design session.")

def cmd_verify(a):
    raw = open(a.file, "rb").read()
    rec = json.loads(raw)
    p = get(f"{BEACON}/chain/{rec['beacon_chain']}/pulse/{rec['beacon_pulse']}")["pulse"]
    first = pulse_at_or_after(rec["pulse_time_ms"])
    checks = {
        "pool is the pool in this script": rec["pool"] == POOL,
        "beacon output matches the published pulse": p["outputValue"] == rec["beacon_output"],
        "pulse is the first at or after the committed time": first["pulseIndex"] == rec["beacon_pulse"],
        "list is the draw for that seed and salt": rec["heldout"] == pick(rec["beacon_output"], rec["salt"], rec["n"]),
    }
    print("list_sha256     =", sha(raw))
    print("salt_commitment =", sha("v3-heldout-salt:" + rec["salt"]))
    print("pulse_time      =", iso(rec["pulse_time_ms"]))
    for k, v in checks.items():
        print("PASS" if v else "FAIL", k)
    print("Compare the three values above with the committed ones.")
    sys.exit(0 if all(checks.values()) else 1)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("seal", "draw"):
        s = sub.add_parser(name)
        s.add_argument("--dir", default="~/v3_heldout_sealed")
        if name == "seal":
            s.add_argument("--delay-min", type=int, default=60, help="minutes until the pulse that seeds the draw")
            s.add_argument("-n", type=int, default=8, help="number of held-out protocols")
    sub.add_parser("verify").add_argument("file")
    a = ap.parse_args()
    {"seal": cmd_seal, "draw": cmd_draw, "verify": cmd_verify}[a.cmd](a)
