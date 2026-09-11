#!/usr/bin/env python3
"""Check the iOS translation resources and explicit L10n.text calls, without Xcode."""
from pathlib import Path
import re,json
ROOT = Path(__file__).resolve().parents[1] / 'CatfolioIOS' / 'CatfolioIOS'
def scan(s):
 i=0
 def string(i):
  start=i;i+=1;key=''
  while i<len(s):
   if s[i]=='"':return i+1,key
   if s[i:i+2]=='\\(':
    i+=2;depth=1
    while depth:
     if s[i]=='"':i,_=string(i);continue
     if s[i]=='(':depth+=1
     if s[i]==')':depth-=1
     i+=1
    key+='%@';continue
   if s[i]=='\\':
    key+=s[i:i+2];i+=2;continue
   key+=s[i];i+=1
  return i,key
 while i<len(s):
  if s[i:i+2]=='//':
   j=s.find('\n',i);i=len(s) if j<0 else j;continue
  if s[i:i+2]=='/*':
   j=s.find('*/',i+2);i=len(s) if j<0 else j+2;continue
  if s[i:i+3]=='"""':
   j=s.find('"""',i+3);i=len(s) if j<0 else j+3;continue
  if s[i]=='"':
   end,key=string(i)
   yield i,end,key
   i=end
  else:i+=1


def main():
    catalogs = {}
    for language in ("en", "zh-Hans"):
        source = (ROOT / f"{language}.lproj" / "Localizable.strings").read_text()
        pairs = re.findall(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");', source)
        entries = [(json.loads(k), json.loads(v)) for k, v in pairs]
        assert len(entries) == len(dict(entries)), f"Duplicate keys in {language}"
        catalogs[language] = dict(entries)
    assert catalogs["en"].keys() == catalogs["zh-Hans"].keys(), "Language keys differ"
    for key, english in catalogs["en"].items():
        assert not re.search("[\u4e00-\u9fff。；、，：！？（）]", english), f"Untranslated English value: {key}"
        assert key.count("%@") == english.count("%@"), f"English placeholders: {key}"
        assert key.count("%@") == catalogs["zh-Hans"][key].count("%@"), f"Chinese placeholders: {key}"
    for name in ["SettingsView.swift", "HistoryView.swift", "TodayDetailView.swift"]:
        source = (ROOT / name).read_text()
        assert 'joined(separator: "。")' not in source, f"Hard-coded sentence punctuation: {name}"
    settings = (ROOT / "SettingsView.swift").read_text()
    assert 'value: L10n.label(model.localSource)' in settings
    assert 'value: L10n.label(account.accountType)' in settings
    # Literal labels can otherwise bypass the translation catalog entirely.
    for start, end, key in scan(settings):
        prefix = settings[max(0, start - 80):start]
        if re.search(r'(?:Text|TextField|Label|Button|Section|accessibilityLabel|accessibilityHint)\($', prefix):
            assert not re.search("[一-鿿。；、]", key), f"Unlocalized Settings label: {key}"
    missing = []
    count = 0
    for path in ROOT.glob("*.swift"):
        source = path.read_text()
        for start, end, key in scan(source):
            if not source[max(0, start - 10):start].endswith("L10n.text("):
                continue
            count += 1
            key = json.loads('"' + key + '"')
            if key not in catalogs["en"]:
                missing.append(f"{path.name}: {key}")
    assert not missing, "Missing translations:\n" + "\n".join(missing)
    # These values route screens, select financial series, or identify synthetic data.
    # Their display labels can be translated; changing their stored values breaks behavior.
    portfolio = (ROOT / "PortfolioView.swift").read_text()
    returns = (ROOT / "ReturnsView.swift").read_text()
    assert 'tableMode = L10n.' not in portfolio
    assert 'case L10n.' not in portfolio
    assert '$0.ticker != "ETF 其他"' in portfolio
    assert 'static let portfolio = "组合"' in returns
    print(f"OK: {len(catalogs['en'])} bilingual keys, {count} localized call sites; stable routing and series identifiers.")

if __name__ == "__main__":
    main()
