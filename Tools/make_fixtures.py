"""開発用：テスト用CSV（Tests/Fixtures）を各種文字コードで生成する。アプリの実行には不要。

各 <名前> について、入力 <名前>.bin と、正しく読めたときの本文 <名前>.expected.txt（UTF-8）を作る。
"""
import codecs
import pathlib

root = pathlib.Path(__file__).resolve().parents[1] / "Tests" / "Fixtures"
root.mkdir(parents=True, exist_ok=True)

BASE = (
    "日付,会員番号,JANコード,金額,割合,メモ\r\n"
    "2026/10/20,00123,4901234567894,-1500,12.5%,\"東京都,新宿区\"\r\n"
    "2026/1/5,000042,4512345678901,\"1,234,567\",3%,\"改行\r\nあり\"\r\n"
    "10/20,1-2,1234567890123456,-1.25,0.5,=1+1\r\n"
    "2026年10月20日,+81312345678,1E3,12.50,08:05,ｶﾀｶﾅ\r\n"
    "2026-10-20 12:34,123456789012,0,1234,37:30,\"引用符\"\"入り\"\r\n"
)
CP932_ONLY = BASE + "髙橋,①,№,∵,～,－\r\n"
EUC_TEXT = BASE + "高橋,森鷗外,〜,−,あいう,テスト\r\n"   # 鷗はJIS X 0212（3バイト）
HALFKANA = "ｱｲｳ,ﾌﾘｺﾐ,ﾔﾏﾀﾞ ﾀﾛｳ\r\n123,456,789\r\n"
SEMICOLON = "名前;値;メモ\r\nりんご;00123;赤い\r\nみかん;-5;\"a;b\"\r\n"


def write(name, raw, expected):
    (root / (name + ".bin")).write_bytes(raw)
    (root / (name + ".expected.txt")).write_bytes(expected.encode("utf-8"))


write("utf8_bom", codecs.BOM_UTF8 + BASE.encode("utf-8"), BASE)
write("utf8", BASE.encode("utf-8"), BASE)
write("cp932", CP932_ONLY.encode("cp932"), CP932_ONLY)
write("eucjp", EUC_TEXT.encode("euc_jp"), EUC_TEXT)
tsv = BASE.replace(",", "\t")
write("utf16le_bom_tab", codecs.BOM_UTF16_LE + tsv.encode("utf-16-le"), tsv)
write("utf16be_bom", codecs.BOM_UTF16_BE + BASE.encode("utf-16-be"), BASE)
write("utf16le_nobom", BASE.encode("utf-16-le"), BASE)
write("bom_plus_sjis", codecs.BOM_UTF8 + BASE.encode("cp932"), BASE)
write("halfkana_sjis", HALFKANA.encode("cp932"), HALFKANA)
write("semicolon", SEMICOLON.encode("utf-8"), SEMICOLON)
broken = BASE.encode("cp932") + b"\x85\x86\xeb\r\n"
write("broken", broken, broken.decode("cp932", errors="replace"))
print("fixtures:", sorted(p.name for p in root.iterdir()))
