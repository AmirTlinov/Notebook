export async function run({id, scenario, base, loader, factory}) {
  const send = (kind, value = {}) => postMessage(JSON.stringify({id, kind, ...value}));
  try {
    const [{loadPyodide}, {default: createPyodideModule}] = await Promise.all([import(loader), import(factory)]);
    const pyodide = await loadPyodide({
      indexURL: base,
      createPyodideModule,
      packages: ['numpy', 'scipy', 'sympy', 'mpmath'],
      stdin: () => null,
      stdout: () => {}, stderr: () => {},
    });
    for (const name of ['numpy', 'scipy', 'scipy.integrate', 'scipy.linalg', 'sympy', 'mpmath']) { send('progress', {phase:name}); await pyodide.runPythonAsync('import ' + name); }
    send('ready');
    if (scenario === 'infinite') {
      pyodide.runPython('while True: pass');
      throw new Error('Infinite loop returned');
    }
    if (scenario === 'science') {
      const result = JSON.parse(pyodide.runPython(`
import sys, json, math, os
import numpy as np
import scipy
from scipy.integrate import quad, solve_ivp
import sympy as sp
import mpmath as mp
x, y = sp.symbols('x y')
mp.mp.dps = 50
answer = {
 'versions': [sys.version.split()[0], np.__version__, scipy.__version__, sp.__version__, mp.__version__],
 'fraction': str(sp.Rational(-3, 4) + sp.Rational(1, 6)),
 'power': str(sp.Integer(-2)**3),
 'nested': str(sp.sin(sp.acos(sp.Rational(3,5)))),
 'derivative': str(sp.diff(sp.sin(x), x)),
 'integral': str(sp.integrate(x*x, (x, 0, 1))),
 'system': {str(k): str(v) for k,v in sp.solve([x+y-3, 2*x-y], [x,y]).items()},
 'matrix': str(sp.Matrix([[1,2],[3,4]]).det()),
 'array': np.linalg.solve([[2.,1.],[1.,3.]], [1.,2.]).tolist(),
 'quad': quad(math.sin, 0, math.pi)[0],
 'model': float(solve_ivp(lambda t,z: -z, (0,1), [1.], rtol=1e-9, atol=1e-12).y[0,-1]),
 'precision': str(mp.sqrt(2)),
 'environmentIsolated': 'NOTEBOOK_HOME' not in os.environ and 'OPENAI_API_KEY' not in os.environ,
}
with open('/tmp/probe-only', 'w') as stream: stream.write('ephemeral')
json.dumps(answer)
`));
      send('result', {value: result});
    } else if (scenario === 'isolation') {
      const network = {};
      for (const [name, url] of Object.entries({https: 'https://example.com/notebook-probe', file: 'file:///etc/passwd', unknown: base+'notebook.sqlite', traversal: base+'%2e%2e/Notebook.sqlite'})) {
        try { const result = await fetch(url); network[name] = !result.ok; }
        catch { network[name] = true; }
      }
      try { new WebSocket('wss://example.com/notebook-probe'); network.websocket = false; }
      catch { network.websocket = true; }
      const value = JSON.parse(pyodide.runPython(`
import json, os, sys, subprocess
try:
 import micropip
 packageInstallerAbsent = False
except ModuleNotFoundError:
 packageInstallerAbsent = True
try:
 subprocess.run(['ls'], check=True)
 systemCommandsAbsent = False
except (OSError, NotImplementedError):
 systemCommandsAbsent = True
json.dumps({'freshFilesystem': not os.path.exists('/tmp/probe-only'), 'freshGlobals': 'answer' not in globals(), 'packageInstallerAbsent': packageInstallerAbsent, 'systemCommandsAbsent': systemCommandsAbsent, 'answer': 6*7})
`));
      send('result', {value: {...value, network}});
    } else if (scenario === 'failure') {
      let caught = false;
      try { pyodide.runPython('import numpy as np\nnp.ones(3).reshape((2,2))'); }
      catch (error) { caught = error.type === 'ValueError'; }
      // WASM has no native floating-point exception flags. Keep this observed
      // incompatibility visible; do not patch NumPy or invent a LinAlgError.
      const numericLimit = JSON.parse(pyodide.runPython(`
import numpy as np, json
matrix = np.linalg.inv(np.zeros((2,2)))
try:
 json.dumps(matrix.tolist(), allow_nan=False)
 nonfiniteRejected = False
except ValueError:
 nonfiniteRejected = True
json.dumps({'singularInverseAllFinite': bool(np.isfinite(matrix).all()), 'nonfiniteResultRejected': nonfiniteRejected})
`));
      send('result', {value: {libraryError: caught, ...numericLimit, afterError: pyodide.runPython('6*7')}});
    } else if (scenario === 'output') {
      // The interpreter owns the bounded capture; the parent never receives a
      // giant string. This is not a guarantee against arbitrary WASM heap growth.
      const value = JSON.parse(pyodide.runPython(`
import io, contextlib, json
class Capture(io.TextIOBase):
 def __init__(self): self.value = ''; self.truncated = False
 def write(self, text):
  remaining = 1024-len(self.value)
  self.value += text[:remaining]
  self.truncated |= len(text) > remaining
  return len(text)
capture=Capture()
with contextlib.redirect_stdout(capture):
 for i in range(10000): print('0123456789')
json.dumps({'length': len(capture.value), 'truncated': capture.truncated})
`));
      send('result', {value});
    } else throw new Error('Unknown scenario');
  } catch (error) { send('failure', {error: String(error).slice(0, 4096)}); }
}
