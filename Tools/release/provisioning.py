#!/usr/bin/env python3
"""Check that a Developer ID provisioning profile grants every entitlement an app is signed with.

Usage: Tools/release/provisioning.py --profile <file.provisionprofile> --entitlements <file.plist>
           --team <TEAMID> --bundle-id <id> [--certificate-sha1 <hash> | --certificate <file.der>] [--write <out>]

The profile is decoded with `security cms -D -i`. Build variables in the entitlements ($(AppIdentifierPrefix),
$(TeamIdentifierPrefix), $(DEVELOPMENT_TEAM), $(PRODUCT_BUNDLE_IDENTIFIER)) are filled in for the team and bundle id
first. The profile must be a macOS Developer ID profile for <team>.<bundle id> that has not expired and, when a
certificate is given, lists that signing certificate. Entitlements under com.apple.security. are not compared: they
need no profile. --write saves the filled-in entitlements for codesign, and only when nothing is wrong.

Exit status: 0 when the profile grants everything (one summary line), 1 with one line per problem, 2 when the
profile or the entitlements cannot be read.
"""

import argparse
import datetime
import hashlib
import plistlib
import re
import subprocess
import sys

APPLICATION_IDENTIFIER = "com.apple.application-identifier"
TEAM_IDENTIFIER = "com.apple.developer.team-identifier"
UNRESTRICTED_PREFIX = "com.apple.security."
VARIABLE = re.compile(r"\$\((\w+)\)")


class Unreadable(Exception):
    pass


def decode_profile(path):
    result = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True, check=False)
    if result.returncode != 0 or not result.stdout:
        reason = result.stderr.decode(errors="replace").strip().splitlines()
        raise Unreadable(f"could not decode {path} as a provisioning profile ({reason[-1] if reason else 'no output'})")
    try:
        profile = plistlib.loads(result.stdout)
    except Exception as error:
        raise Unreadable(f"{path} does not hold a property list ({error})")
    if not isinstance(profile, dict):
        raise Unreadable(f"{path} does not hold a provisioning profile")
    return profile


def read_entitlements(path):
    try:
        with open(path, "rb") as handle:
            entitlements = plistlib.load(handle)
    except Exception as error:
        raise Unreadable(f"could not read the entitlements {path} ({error})")
    if not isinstance(entitlements, dict):
        raise Unreadable(f"{path} is not an entitlements dictionary")
    return entitlements


def expand(value, team, bundle_id):
    names = {"AppIdentifierPrefix": team + ".", "TeamIdentifierPrefix": team + ".", "DEVELOPMENT_TEAM": team,
             "PRODUCT_BUNDLE_IDENTIFIER": bundle_id}
    if isinstance(value, str):
        return VARIABLE.sub(lambda match: names.get(match.group(1), match.group(0)), value)
    if isinstance(value, list):
        return [expand(item, team, bundle_id) for item in value]
    if isinstance(value, dict):
        return {key: expand(item, team, bundle_id) for key, item in value.items()}
    return value


def _strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)


def _grants_one(granted, wanted):
    if isinstance(granted, str) and isinstance(wanted, str):
        if granted == "*":
            return True
        if granted.endswith("*"):
            return wanted.startswith(granted[:-1])
    return type(granted) is type(wanted) and granted == wanted


def grants(granted, wanted):
    allowed = granted if isinstance(granted, list) else [granted]
    if isinstance(wanted, list):
        return all(any(_grants_one(g, w) for g in allowed) for w in wanted)
    return any(_grants_one(g, wanted) for g in allowed)


def _show(value):
    if isinstance(value, list):
        return "[" + ", ".join(_show(item) for item in value) + "]"
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def certificate_sha1(der):
    return hashlib.sha1(der).hexdigest().upper()


def problems(profile, entitlements, team, bundle_id, certificate=None, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    granted = profile.get("Entitlements") if isinstance(profile.get("Entitlements"), dict) else {}
    app_id = f"{team}.{bundle_id}"
    found = []

    platforms = profile.get("Platform") or []
    if "OSX" not in platforms:
        found.append(f"the profile is for {_show(platforms) if platforms else 'no platform'}, not macOS")
    if profile.get("ProvisionedDevices"):
        found.append("the profile lists devices, so it is a development profile. Download the Developer ID profile "
                     "for this App ID")
    teams = profile.get("TeamIdentifier") or []
    if team not in teams:
        found.append(f"the profile belongs to team {_show(teams) if teams else 'none'}, but the app is signed by "
                     f"team {team}")
    profile_app_id = granted.get(APPLICATION_IDENTIFIER)
    if profile_app_id != app_id:
        found.append(f"the profile is for App ID {profile_app_id or 'none'}, but this app is {app_id}")
    if entitlements.get(APPLICATION_IDENTIFIER, app_id) != app_id:
        found.append(f"{APPLICATION_IDENTIFIER} is {_show(entitlements[APPLICATION_IDENTIFIER])}, but this app is "
                     f"{app_id}")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime):
        found.append("the profile has no expiry date")
    elif expires <= now:
        found.append(f"the profile expired on {expires:%Y-%m-%d}. Download a new one")
    if certificate is not None:
        listed = {certificate_sha1(c) for c in profile.get("DeveloperCertificates") or [] if isinstance(c, bytes)}
        if certificate.upper() not in listed:
            found.append(f"the profile does not list the signing certificate (SHA-1 {certificate.upper()}). "
                         f"Generate the profile again with that Developer ID Application certificate")

    restricted = {key: value for key, value in entitlements.items() if not key.startswith(UNRESTRICTED_PREFIX)}
    if restricted:
        for key in (APPLICATION_IDENTIFIER, TEAM_IDENTIFIER):
            if key not in entitlements:
                found.append(f"the entitlements lack {key}, which ties the app to its profile")
    for key, value in sorted(restricted.items()):
        unknown = sorted({m.group(1) for text in _strings(value) for m in VARIABLE.finditer(text)})
        if key == APPLICATION_IDENTIFIER and not unknown:
            continue
        if unknown:
            found.append(f"{key} keeps the build variable(s) {', '.join('$(' + name + ')' for name in unknown)}, "
                         f"which this check does not fill in")
        elif key not in granted:
            found.append(f"the profile does not grant {key}")
        elif not grants(granted[key], value):
            found.append(f"{key}: the app asks for {_show(value)}, the profile grants {_show(granted[key])}")
    return found


def summary(profile, team, bundle_id):
    expires = profile.get("ExpirationDate")
    return (f"profile '{profile.get('Name', 'unnamed')}' ({profile.get('UUID', 'no UUID')}) grants every "
            f"entitlement: team {team}, App ID {team}.{bundle_id}, expires {expires:%Y-%m-%d}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--profile", required=True)
    parser.add_argument("--entitlements", required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--bundle-id", required=True)
    certificate = parser.add_mutually_exclusive_group()
    certificate.add_argument("--certificate-sha1")
    certificate.add_argument("--certificate")
    parser.add_argument("--write")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error(f"--team must be a 10-character team id, not {args.team!r}")

    try:
        profile = decode_profile(args.profile)
        entitlements = expand(read_entitlements(args.entitlements), args.team, args.bundle_id)
        sha1 = args.certificate_sha1
        if args.certificate:
            with open(args.certificate, "rb") as handle:
                sha1 = certificate_sha1(handle.read())
    except (Unreadable, OSError) as error:
        print(error, file=sys.stderr)
        return 2

    found = problems(profile, entitlements, args.team, args.bundle_id, certificate=sha1)
    if found:
        print("\n".join(found))
        return 1
    if args.write:
        try:
            with open(args.write, "wb") as handle:
                plistlib.dump(entitlements, handle)
        except OSError as error:
            print(f"could not write {args.write} ({error})", file=sys.stderr)
            return 2
    print(summary(profile, args.team, args.bundle_id))
    return 0


if __name__ == "__main__":
    sys.exit(main())
