"""Locate installed tools. Explicit overrides are checked and never ignored."""
from pathlib import Path
import os, shutil, tempfile

ROOT = Path(__file__).resolve().parents[1]

def _override(name, suffix=None):
    value = os.environ.get(name)
    if not value:
        return None
    p = Path(value).expanduser()
    if suffix:
        p = p/suffix
    if not p.is_file():
        raise FileNotFoundError(f'{name} points to a missing file: {p}')
    return p.resolve()

def gowin_exe(name):
    if name == 'gw_sh.exe':
        explicit = _override('GOWIN_SH')
        if explicit:
            return explicit
    explicit = _override('GOWIN_IDE_BIN', name)
    if explicit:
        return explicit
    candidates = []
    if shutil.which(name):
        candidates.append(Path(shutil.which(name)))
    for base in [Path('D:/Gowin'), Path('C:/Gowin'), Path('D:/fpga/Gowin')]:
        if base.is_dir():
            candidates += [p/name for p in sorted(base.glob('*/IDE/bin'), reverse=True)]
    for p in candidates:
        if p.is_file():
            return p.resolve()
    raise FileNotFoundError(f'{name} not found; set GOWIN_IDE_BIN to the installed IDE/bin directory')

def gowin_simlib():
    explicit = _override('GOWIN_SIMLIB')
    if explicit:
        return explicit
    p = gowin_exe('gw_sh.exe').parent.parent/'simlib/gw5a/prim_sim.v'
    if not p.is_file():
        raise FileNotFoundError(f'Gowin GW5A simulation library missing: {p}')
    return p

def iverilog_exe():
    explicit = _override('IVERILOG_BIN')
    if explicit:
        return explicit
    candidates = []
    if shutil.which('iverilog.exe'):
        candidates.append(Path(shutil.which('iverilog.exe')))
    candidates += [Path('C:/iverilog/bin/iverilog.exe'), Path('C:/msys64/ucrt64/bin/iverilog.exe'),
                   Path('D:/fpga/msys64/ucrt64/bin/iverilog.exe')]
    for p in candidates:
        if p.is_file() and p.with_name('vvp.exe').is_file():
            return p.resolve()
    raise FileNotFoundError('Icarus not found; set IVERILOG_BIN to iverilog.exe')

def english_cache(kind):
    setting = 'XIANCHU_BUILD_ROOT' if kind == 'build' else 'XIANCHU_VIEW_ROOT'
    p = Path(os.environ.get(setting) or str(Path(tempfile.gettempdir())/'XianChu'/kind)).resolve()
    if not str(p).isascii():
        raise ValueError(f'{setting} must name an English-only path for Gowin')
    return p
