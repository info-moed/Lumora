import os
import pickle
import sys
import __main__

DATA = os.path.expanduser('~/Library/Caches/Lumora-Bench/qc-scorer')


class Scorer:
    pass


__main__.Scorer = Scorer
s = pickle.load(open(os.path.join(DATA, 'scorer-alt.pkl'), 'rb'))
models = {'quality': s.quality}
for c, g in s.gains.items():
    models[f'gain.{c}'] = g
log = [l.replace('    ', '    alt ', 1) for l in s.log]
pickle.dump((models, log), open(os.path.join(DATA, 'models-alt.pkl'), 'wb'))
print(sorted(models), file=sys.stderr)
