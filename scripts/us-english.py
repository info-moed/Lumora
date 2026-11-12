#!/usr/bin/env python3
"""Keep Lumora in US English: convert British spellings, or check that none are left.

  python3 scripts/us-english.py --check [FILES...]   # exit 1 and list lines with British spellings (default: all text files)
  python3 scripts/us-english.py --dry   [FILES...]   # show what would change
  python3 scripts/us-english.py         [FILES...]   # convert in place

Whole words only, case kept. Text in `code` spans or code blocks is never changed, and words joined to "-" or "_"
are left alone, because tool options and identifiers keep
their real spelling (mkvmerge --white-colour-coordinates, FFmpeg colour_primaries, VVenC MasteringDisplayColourVolume).
Ambiguous words that are valid US English ("analyses", "characteristic", "emphasis") are never touched.
"""
import re, subprocess, sys

W = {
 # -our
 'colour': 'color', 'colours': 'colors', 'coloured': 'colored', 'colouring': 'coloring', 'colourful': 'colorful',
 'colourist': 'colorist', 'colourists': 'colorists', 'colourspace': 'colorspace', 'colourless': 'colorless',
 'colourfulness': 'colorfulness', 'behaviour': 'behavior', 'behaviours': 'behaviors', 'favourite': 'favorite',
 'favourites': 'favorites', 'favour': 'favor', 'favours': 'favors', 'favoured': 'favored', 'honour': 'honor',
 'honours': 'honors', 'honoured': 'honored', 'neighbour': 'neighbor', 'neighbours': 'neighbors',
 'neighbouring': 'neighboring', 'flavour': 'flavor', 'flavours': 'flavors', 'humour': 'humor', 'vapour': 'vapor',
 'labour': 'labor', 'harbour': 'harbor', 'rumour': 'rumor',
 # -ence / -re / other nouns
 'licence': 'license', 'licences': 'licenses', 'defence': 'defense', 'defences': 'defenses', 'offence': 'offense',
 'pretence': 'pretense', 'centre': 'center', 'centres': 'centers', 'centred': 'centered', 'metre': 'meter',
 'metres': 'meters', 'fibre': 'fiber', 'theatre': 'theater', 'catalogue': 'catalog', 'catalogues': 'catalogs',
 'analogue': 'analog', 'programme': 'program', 'programmes': 'programs', 'grey': 'gray', 'greys': 'grays',
 'greyscale': 'grayscale', 'greyed': 'grayed', 'judgement': 'judgment', 'judgements': 'judgments',
 'artefact': 'artifact', 'artefacts': 'artifacts', 'maths': 'math', 'sceptic': 'skeptic', 'sceptical': 'skeptical',
 'whilst': 'while', 'amongst': 'among', 'towards': 'toward', 'learnt': 'learned', 'spelt': 'spelled',
 'dreamt': 'dreamed', 'fulfil': 'fulfill', 'enrol': 'enroll', 'anaemic': 'anemic', 'aluminium': 'aluminum',
 'practise': 'practice', 'practised': 'practiced',
 # doubled l
 'labelled': 'labeled', 'labelling': 'labeling', 'modelling': 'modeling', 'modelled': 'modeled',
 'signalling': 'signaling', 'signalled': 'signaled', 'cancelled': 'canceled', 'cancelling': 'canceling',
 'travelled': 'traveled', 'travelling': 'traveling', 'levelled': 'leveled', 'levelling': 'leveling',
 'fuelled': 'fueled', 'totalled': 'totaled', 'tunnelling': 'tunneling', 'channelled': 'channeled',
 'channelling': 'channeling', 'marshalled': 'marshaled', 'modeller': 'modeler',
 # analyse
 'analyse': 'analyze', 'analysed': 'analyzed', 'analysing': 'analyzing', 'analyser': 'analyzer', 'paralyse': 'paralyze',
}
ISE = ['optimis', 'normalis', 'recognis', 'organis', 'sanitis', 'summaris', 'minimis', 'maximis', 'prioritis', 'utilis',
       'characteris', 'synchronis', 'initialis', 'customis', 'standardis', 'realis', 'generalis', 'apologis',
       'emphasis', 'visualis', 'serialis', 'finalis', 'localis', 'categoris', 'authoris', 'specialis', 'stabilis',
       'criticis', 'memoris', 'randomis', 'parametris', 'linearis', 'quantis', 'tokenis', 'capitalis', 'centralis',
       'penalis', 'harmonis', 'neutralis', 'equalis', 'digitalis', 'materialis', 'legitimis', 'modernis',
       'personalis', 'globalis', 'theoris', 'itemis', 'sensitis', 'desensitis', 'regularis', 'binaris', 'vectoris']
WORDS = re.compile(r'(?<![-_])\b(' + '|'.join(sorted(W, key=len, reverse=True)) + r')\b(?![-_])', re.I)
ISES = re.compile(r'(?<![-_])\b(' + '|'.join(sorted(set(ISE), key=len, reverse=True))
                  + r')(ations|ation|able|ers|ing|ed|es|er|e)\b(?![-_])', re.I)
TEXT = ('.md', '.swift', '.metal', '.h', '.py', '.sh', '.yml', '.json', '.txt')
SKIP = ('docs/encoding/', 'scripts/us-english.py')   # generated from encoder data that quotes tools' own spellings verbatim (e.g. Matroska "Colour")


def keep_case(src, dst):
    if src.isupper():
        return dst.upper()
    return dst[0].upper() + dst[1:] if src[0].isupper() else dst


CODE = re.compile(r"(```.*?```|`[^`\n]*`)", re.S)


def convert(text):
    """Converts prose only: code spans and fenced code blocks keep their exact text (real names live there)."""
    return "".join(part if CODE.fullmatch(part) else convert_prose(part) for part in CODE.split(text))


def convert_prose(text):
    text = WORDS.sub(lambda m: keep_case(m.group(0), W[m.group(0).lower()]), text)

    def ise(m):
        stem, suf = m.group(1), m.group(2)
        if stem.lower() == 'emphasis' and suf.lower() not in ('e', 'ed', 'es', 'ing'):
            return m.group(0)
        return keep_case(stem, stem[:-1] + ('Z' if stem[-1].isupper() else 'z')) + suf
    return ISES.sub(ise, text)


def main(argv):
    mode = 'write'
    files = []
    for a in argv:
        if a in ('--check', '--dry'):
            mode = a[2:]
        else:
            files.append(a)
    if not files:
        files = subprocess.run(['git', 'ls-files'], capture_output=True, text=True).stdout.split()
    files = [f for f in files if f.endswith(TEXT) and not f.startswith(SKIP)]
    hits = changed = 0
    for f in files:
        try:
            s = open(f, encoding='utf-8').read()
        except (OSError, UnicodeDecodeError):
            continue
        t = convert(s)
        if t == s:
            continue
        changed += 1
        if mode == 'write':
            open(f, 'w', encoding='utf-8').write(t)
            continue
        for n, (a, b) in enumerate(zip(s.splitlines(), t.splitlines()), 1):
            if a != b:
                hits += 1
                print(f"{f}:{n}: {b.strip()[:160]}")
    if mode == 'write':
        print(f"{changed} files converted to US English")
        return 0
    if mode == 'check':
        print(f"{hits} line(s) with British spellings in {changed} file(s)" if hits else "US English: OK")
        return 1 if hits else 0
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
