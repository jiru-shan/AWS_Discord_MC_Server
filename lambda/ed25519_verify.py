"""Dependency-free Ed25519 signature verification (RFC 8032).

Discord signs every interaction request with Ed25519 and requires the endpoint
to reject bad signatures with a 401. The usual way to do that in Python is
PyNaCl, but PyNaCl ships a compiled C extension, which means either vendoring a
manylinux wheel into the deployment package or maintaining a Lambda layer.

This module implements verification in pure Python instead, so the Lambda has
zero dependencies outside the runtime and Terraform can zip the source directly.
Verification takes roughly 30 ms, which is comfortably inside Discord's 3 second
budget. Only *verification* lives here -- there is no signing, and no secret key
ever touches this code, so the lack of constant-time arithmetic is not a
concern: every value involved is public.

Correctness is pinned by the RFC 8032 section 7.1 test vectors in
tests/test_ed25519_verify.py.
"""

import hashlib

# Curve25519 field / group parameters, per RFC 8032 section 5.1.
P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)

# Points are held in extended homogeneous coordinates (X, Y, Z, T) where
# x = X/Z, y = Y/Z and x*y = T/Z. This keeps the group law inversion-free.


def _recover_x(y, sign):
    """Return the x matching this y and sign bit, or None if y is not on the curve."""
    if y >= P:
        return None
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P)
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P != 0:
        x = x * SQRT_M1 % P
    if (x * x - xx) % P != 0:
        return None
    if x == 0 and sign:
        return None
    if x & 1 != sign:
        x = P - x
    return x


_BASE_Y = 4 * pow(5, P - 2, P) % P
_BASE_X = _recover_x(_BASE_Y, 0)
BASE_POINT = (_BASE_X, _BASE_Y, 1, _BASE_X * _BASE_Y % P)
IDENTITY = (0, 1, 1, 0)


def _add(p1, p2):
    """add-2008-hwcd-3, the addition law for twisted Edwards curves with a = -1."""
    x1, y1, z1, t1 = p1
    x2, y2, z2, t2 = p2
    a = (y1 - x1) * (y2 - x2) % P
    b = (y1 + x1) * (y2 + x2) % P
    c = 2 * t1 * t2 * D % P
    dd = 2 * z1 * z2 % P
    e, f, g, h = b - a, dd - c, dd + c, b + a
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _double(p1):
    """dbl-2008-hwcd, specialised for a = -1. Cheaper than _add(p, p)."""
    x1, y1, z1, _ = p1
    a = x1 * x1 % P
    b = y1 * y1 % P
    c = 2 * z1 * z1 % P
    e = ((x1 + y1) * (x1 + y1) - a - b) % P
    g = b - a
    f = g - c
    h = -(a + b) % P
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _scalar_mult(point, scalar):
    """Fixed-length double-and-add. Runs the full 256 bits so the loop count does
    not leak the scalar, even though nothing secret is multiplied here."""
    result = IDENTITY
    addend = point
    for _ in range(256):
        if scalar & 1:
            result = _add(result, addend)
        addend = _double(addend)
        scalar >>= 1
    return result


def _decompress(data):
    """Decode a 32 byte little-endian point encoding, or None if it is malformed."""
    if len(data) != 32:
        return None
    value = int.from_bytes(data, "little")
    sign = value >> 255
    y = value & ((1 << 255) - 1)
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % P)


def _equal(p1, p2):
    """Projective equality: x1/z1 == x2/z2 and y1/z1 == y2/z2."""
    x1, y1, z1, _ = p1
    x2, y2, z2, _ = p2
    return (x1 * z2 - x2 * z1) % P == 0 and (y1 * z2 - y2 * z1) % P == 0


def verify(public_key, signature, message):
    """Return True if `signature` is a valid Ed25519 signature over `message`.

    All three arguments are bytes. Any malformed input returns False rather than
    raising, so a hostile caller cannot turn a bad signature into a 500.
    """
    if len(signature) != 64 or len(public_key) != 32:
        return False

    a_point = _decompress(public_key)
    r_point = _decompress(signature[:32])
    if a_point is None or r_point is None:
        return False

    s = int.from_bytes(signature[32:], "little")
    if s >= L:  # non-canonical scalar; RFC 8032 requires rejecting these
        return False

    digest = hashlib.sha512(signature[:32] + public_key + message).digest()
    h = int.from_bytes(digest, "little") % L

    # Valid iff [s]B == R + [h]A.
    return _equal(_scalar_mult(BASE_POINT, s), _add(r_point, _scalar_mult(a_point, h)))


def verify_hex(public_key_hex, signature_hex, message):
    """verify() for the hex-encoded forms Discord sends. Bad hex returns False."""
    try:
        public_key = bytes.fromhex(public_key_hex)
        signature = bytes.fromhex(signature_hex)
    except (ValueError, TypeError):
        return False
    return verify(public_key, signature, message)
