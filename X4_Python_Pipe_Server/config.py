import argparse
import json
from pathlib import Path
import sys
import logging

permissions_path = None
permissions = None

def setup_paths():
    """Set up sys.path for package inclusion."""
    if not getattr(sys, 'frozen', False):
        home_path = Path(__file__).resolve().parents[1]
        if str(home_path) not in sys.path:
            sys.path.append(str(home_path))
            logging.getLogger(__name__).debug(f"Added {home_path!r} to sys.path")

def parse_args():
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description='Host pipe server for X4 interprocess communication.'
    )
    parser.add_argument('-p', '--permissions-path', help='Path to permissions.json.')
    parser.add_argument('-t', '--test', action='store_true', help='Enable test mode.')
    parser.add_argument('-x', '--x4-path', help='X4 installation path (test mode).')
    parser.add_argument('-m', '--module', help='Module path (test mode).')
    parser.add_argument('-v', '--verbose', action='store_true', help='Verbose output.')
    parser.add_argument('--no-restart', SPSSaction='store_true', help='Disable auto-restart.')

    args = parser.parse_args()

    logger = logging.getLogger(__name__)
    if args.verbose:
        logger.setLevel(logging.DEBUG)
        logger.debug("Verbose mode enabled")

    if args.test:
        if not args.x4_path or not args.module:
            logger.error("Test mode requires both --x4-path and --module")
            sys.exit(1)
        logger.info(f"Test mode ON: X4 root = {args.x4_path}, module = {args.module}")

    return args

def load_permissions(args):
    """Load or generate the permissions file."""
    global permissions, permissions_path
    logger = logging.getLogger(__name__)

    if getattr(sys, 'frozen', False):
        permissions_path = Path(sys.executable).parent / 'permissions.json'
    else:
        permissions_path = Path(__file__).resolve().parent / 'permissions.json'

    if args.permissions_path:
        permissions_path = Path(args.permissions_path).resolve()
        logger.debug(f"Overriding permissions path: {permissions_path}")

    if permissions_path.exists():
        try:
            permissions = json.loads(permissions_path.read_text())
            logger.info(f"Loaded permissions from {permissions_path}")
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse permissions.json: {e}")
            permissions = None

    if not permissions:
        permissions = {
            'instructions': 'Set allowed extension IDs or folder names. IDs take precedence.',
            'ws_2042901274': True
        }
        permissions_path.write_text(json.dumps(permissions, indent=2))
        logger.info(f"Initialized default permissions at {permissions_path}")

def check_permission(x4_path, module_path):
    """Verify module permission using extension ID or folder name."""
    logger = logging.getLogger(__name__)
    try:
        if not module_path.as_posix().startswith('extensions/'):
            raise ValueError("Module not in extensions directory")

        ext_dir = x4_path / module_path.parents[-3]
        content_xml = ext_dir / 'content.xml'
        logger.debug(f"Checking permissions in {content_xml}")
        content = content_xml.read_text()
        ext_id = content.split('id="')[1].split('"')[0]
        folder = ext_dir.name

        if permissions.get(ext_id):
            logger.debug(f"Permission granted by ID {ext_id}")
            return True
        if permissions.get(folder):
            logger.debug(f"Permission granted by folder name {folder}")
            return True

        logger.warning(f"Permission denied for module {module_path} (ID={ext_id}, folder={folder})")
        return False
    except Exception as e:
        logger.error(f"Permission check error for {module_path}: {e}")
        return False