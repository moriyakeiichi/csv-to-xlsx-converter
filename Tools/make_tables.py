"""開発用：文字コード表（Resources/*.bin）を生成する。アプリの実行には不要。

Python標準のcp932 / euc_jpコーデックから、バイト列→Unicodeの対応表を作る。
  cp932.bin   : 1バイト(0x00-0xFF)と2バイト(上位<<8|下位)の表。65536要素×UInt32（リトルエンディアン）
  eucjp.bin   : EUC-JPの1バイト・2バイトの表。同じ形式
  eucjp3.bin  : EUC-JPの3バイト（0x8F＋2バイト）の表。添字は2・3バイト目
対応がない位置は0xFFFFFFFF。
"""
import pathlib
import struct
import sys

out = pathlib.Path(__file__).resolve().parents[1] / "Resources"
out.mkdir(exist_ok=True)
INVALID = 0xFFFFFFFF


def one(raw, codec):
    try:
        text = raw.decode(codec, errors="strict")
    except UnicodeDecodeError:
        return INVALID
    return ord(text) if len(text) == 1 else INVALID


def write(name, table):
    (out / name).write_bytes(struct.pack("<65536I", *table))


for codec, name in (("cp932", "cp932.bin"), ("euc_jp", "eucjp.bin")):
    table = [INVALID] * 65536
    for v in range(256):
        table[v] = one(bytes([v]), codec)
    for v in range(256, 65536):
        table[v] = one(v.to_bytes(2, "big"), codec)
    write(name, table)

table3 = [INVALID] * 65536
for v in range(65536):
    table3[v] = one(b"\x8f" + v.to_bytes(2, "big"), "euc_jp")
write("eucjp3.bin", table3)

(out / "TABLES.txt").write_text(
    "cp932.bin / eucjp.bin / eucjp3.bin\n"
    "Python " + sys.version.split()[0] + " の cp932・euc_jp コーデックから Tools/make_tables.py で生成。\n"
)
print("ok")
