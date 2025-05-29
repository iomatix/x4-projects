import argparse
import sys
import os
import shutil
from pathlib import Path
import subprocess
import time

# Conditional import of pyinstaller, checking if it is available.
try:
    import PyInstaller
    pyinstaller_found = True
except ImportError:
    pyinstaller_found = False

This_dir = Path(__file__).parent

def Clear_Dir(dir_path: Path):
    '''
    Clears contents of the given directory.
    Retries up to 10 times if permission errors occur.
    '''
    if dir_path.exists():
        for _ in range(10):
            try:
                shutil.rmtree(dir_path)
                break
            except PermissionError:
                time.sleep(0.15)  # Wait briefly before retrying
            except Exception as e:
                print(f"Error removing directory {dir_path}: {e}")
                break
    return

def Make(*args):
    # Set up command line arguments.
    argparser = argparse.ArgumentParser(
        description='Generate an executable from the X4 Customizer source python code, using pyinstaller.'
    )
    
    argparser.add_argument(
        '-preclean',
        action='store_true',
        help='Force pyinstaller to do a fresh compile, ignoring any work from a prior build.'
    )
    
    argparser.add_argument(
        '-postclean',
        action='store_true',
        help='Delete the pyinstaller work folder when done, though this will slow down rebuilds.'
    )
    
    argparser.add_argument(
        '-onedir',
        action='store_true',
        help='Puts files separated into a folder, mainly to aid in debug, though also skips needing to unpack into a temp folder.'
    )
    
    # Parse the input args.
    args, remainder = argparser.parse_known_args(args)

    if not pyinstaller_found:
        raise RuntimeError('PyInstaller not found')

    # Define output folder paths.
    build_folder = (This_dir / '..' / 'build').resolve()
    dist_folder = (This_dir / '..' / 'bin').resolve()
    spec_file_path = This_dir / 'X4_Python_Pipe_Server.spec'

    # Change working directory to script's directory.
    original_cwd = Path.cwd()
    os.chdir(This_dir)

    # Set program name.
    program_name = 'X4_Python_Pipe_Server'

    # Clear existing dist directory if it exists.
    if dist_folder.exists():
        Clear_Dir(dist_folder)

    # Extract version from change_log.md.
    version = ''
    with (This_dir / 'change_log.md').open('r') as file:
        for line in reversed(file.readlines()):
            if line.strip().startswith('*'):
                version = line.replace('*', '').strip()
                break

    # Update version in Main.py if changed.
    main_path = This_dir / 'Main.py'
    main_text = main_path.read_text()
    for line in main_text.splitlines():
        if line.startswith('version ='):
            new_line = f"version = '{version}'"
            if line != new_line:
                main_text = main_text.replace(line, new_line)
                main_path.write_text(main_text)
            break

    # Prepare the specification file for pyinstaller.
    spec_lines = [
        'a = Analysis(',
        '    [',
        '        "Main.py",',
        '    ],',
        f'    pathex = [r"{This_dir}"],',
        '    binaries = [],',
        '    datas = [],',
        '    hiddenimports = [',
        '        r"pynput",',
        '        r"time",',
        '        r"configparser",',
        '        r"win32gui",',
        '        r"win32file",',
        '    ],',
        '    hookspath = [],',
        '    excludes = [],',
        '    win_no_prefer_redirects = False,',
        '    win_private_assemblies = False,',
        '    cipher = None,',
        '    noarchive = False,',
        ')',
        '',
        'pyz = PYZ(a.pure, a.zipped_data,',
        '     cipher = None,',
        ')',
        '',
    ]

    if not args.onedir:
        spec_lines += [
            'exe = EXE(pyz,',
            '    a.scripts,',
            '    a.binaries,',
            '    a.zipfiles,',
            '    a.datas,',
            '    [],',
            f'    name = "{program_name}",',
            '    debug = False,',
            '    bootloader_ignore_signals = False,',
            '    strip = False,',
            '    upx = True,',
            '    runtime_tmpdir = None,',
            '    console = True,',
            '    windowed = False,',
            ')',
            '',
        ]
    else:
        spec_lines += [
            'exe = EXE(pyz,',
            '    a.scripts,',
            '    exclude_binaries = True,',
            f'    name = "{program_name}",',
            '    debug = False,',
            '    strip = False,',
            '    upx = True,',
            '    console = True,',
            '    windowed = False,',
            ')',
            '',
            'coll = COLLECT(exe,',
            '    a.binaries,',
            '    a.zipfiles,',
            '    a.datas,',
            '    strip = False,',
            '    upx = True,',
            f'    name = "{program_name}",',
            ')',
            '',
        ]

    # Write the spec file.
    spec_file_path.write_text('\n'.join(spec_lines))

    # Prepare and run pyinstaller command.
    pyinstaller_call_args = [
        'python',
        '-m', 'PyInstaller',
        str(spec_file_path),
        '--distpath', str(dist_folder),
        '--workpath', str(build_folder),
    ]

    if args.preclean and build_folder.exists():
        Clear_Dir(build_folder)

    subprocess.run(pyinstaller_call_args)

    # Verify executable creation.
    exe_path = dist_folder / (program_name if args.onedir else '') / f'{program_name}.exe'
    if not exe_path.exists():
        print('Executable not created.')
        return

    # Handle onedir mode: move files up one level.
    if args.onedir:
        path_to_exe_files = dist_folder / program_name
        for path in path_to_exe_files.iterdir():
            dest_path = dist_folder / path.name
            if not dest_path.exists():
                shutil.move(str(path), str(dest_path))
        Clear_Dir(path_to_exe_files)

    # Clean up spec file.
    spec_file_path.unlink()

    # Clean build folder if requested.
    if args.postclean and build_folder.exists():
        Clear_Dir(build_folder)

    # Restore original working directory.
    os.chdir(original_cwd)

if __name__ == '__main__':
    Make(*sys.argv[1:])