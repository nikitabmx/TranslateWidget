# Flips ShowTabView to false inside the window-settings (bwsp) record of a
# Finder .DS_Store, in place: a binary-plist boolean is one byte (0x09 true,
# 0x08 false), so nothing else in the file has to move.
import plistlib, re, sys

path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
m = re.search(rb'bwspblob', data)
if not m:
    sys.exit("no bwsp record")
length = int.from_bytes(data[m.end():m.end() + 4], 'big')
start = m.end() + 4
blob = bytes(data[start:start + length])

trailer = blob[-32:]
off_size, ref_size = trailer[6], trailer[7]
num_objects = int.from_bytes(trailer[8:16], 'big')
top = int.from_bytes(trailer[16:24], 'big')
table = int.from_bytes(trailer[24:32], 'big')
offsets = [int.from_bytes(blob[table + i * off_size:table + (i + 1) * off_size], 'big') for i in range(num_objects)]

def obj(i):
    return offsets[i]

pos = obj(top)
marker = blob[pos]
if marker >> 4 != 0xD:
    sys.exit("bwsp top object is not a dict")
count = marker & 0x0F
pos += 1
if count == 0x0F:  # count stored as a following int object
    size = 1 << (blob[pos] & 0x0F)
    count = int.from_bytes(blob[pos + 1:pos + 1 + size], 'big')
    pos += 1 + size
refs = [int.from_bytes(blob[pos + i * ref_size:pos + (i + 1) * ref_size], 'big') for i in range(2 * count)]
keys, values = refs[:count], refs[count:]

def string_at(i):
    p = obj(i)
    kind, n = blob[p] >> 4, blob[p] & 0x0F
    if kind != 0x5:
        return None
    p += 1
    if n == 0x0F:
        size = 1 << (blob[p] & 0x0F)
        n = int.from_bytes(blob[p + 1:p + 1 + size], 'big')
        p += 1 + size
    return blob[p:p + n].decode('ascii')

names = [string_at(k) for k in keys]
if 'ShowTabView' not in names:
    sys.exit("no ShowTabView key")
value_ref = values[names.index('ShowTabView')]
if blob[obj(value_ref)] == 0x08:
    print("tab bar already hidden")
    sys.exit(0)
if blob[obj(value_ref)] != 0x09 or values.count(value_ref) != 1:
    sys.exit("ShowTabView's true object is shared — not patching")

before = plistlib.loads(blob)
data[start + obj(value_ref)] = 0x08
after = plistlib.loads(bytes(data[start:start + length]))
expected = dict(before, ShowTabView=False)
if after != expected:
    sys.exit("patch verification failed — not writing")
open(path, 'wb').write(data)
print("tab bar hidden:", after)
