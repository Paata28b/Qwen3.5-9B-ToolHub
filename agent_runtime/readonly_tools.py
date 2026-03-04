import json
import os
from pathlib import Path
from typing import Union

from qwen_agent.tools.base import BaseTool, register_tool

DEFAULT_ROOT = '/mnt/d/dev/Qwen3.5'
DEFAULT_MAX_READ_BYTES = 512 * 1024


def _resolve_root() -> Path:
    root = os.getenv('READONLY_FS_ROOT', DEFAULT_ROOT)
    return Path(os.path.expanduser(root)).resolve()


def _resolve_target(raw_path: str) -> Path:
    return Path(os.path.expanduser(raw_path)).resolve()


def _ensure_within_root(target: Path, root: Path) -> None:
    try:
        target.relative_to(root)
    except ValueError as exc:
        raise PermissionError(f'只允许访问根目录 {root} 内的路径，拒绝: {target}') from exc


@register_tool('filesystem', allow_overwrite=True)
class ReadOnlyFilesystemTool(BaseTool):
    description = '只读文件系统工具，支持 list 和 read 两种操作。'
    parameters = {
        'type': 'object',
        'properties': {
            'operation': {
                'type': 'string',
                'description': '仅支持 list|read'
            },
            'path': {
                'type': 'string',
                'description': '目标路径'
            },
        },
        'required': ['operation', 'path'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params = self._verify_json_format_args(params)
        operation = str(params['operation']).strip().lower()
        if operation not in {'list', 'read'}:
            raise PermissionError(f'只读策略已启用，禁止 operation={operation}')

        root = _resolve_root()
        target = _resolve_target(str(params['path']))
        _ensure_within_root(target, root)
        if operation == 'list':
            return self._list_path(target)
        return self._read_file(target)

    def _list_path(self, target: Path) -> str:
        if not target.exists():
            raise FileNotFoundError(f'路径不存在: {target}')
        if target.is_file():
            stat = target.stat()
            payload = {'type': 'file', 'path': str(target), 'size': stat.st_size}
            return json.dumps(payload, ensure_ascii=False)

        items = []
        for child in sorted(target.iterdir()):
            item_type = 'dir' if child.is_dir() else 'file'
            size = child.stat().st_size if child.is_file() else None
            items.append({'name': child.name, 'type': item_type, 'size': size})
        payload = {'type': 'dir', 'path': str(target), 'items': items}
        return json.dumps(payload, ensure_ascii=False, indent=2)

    def _read_file(self, target: Path) -> str:
        if not target.exists() or not target.is_file():
            raise FileNotFoundError(f'文件不存在: {target}')
        limit = int(os.getenv('READONLY_FS_MAX_READ_BYTES', str(DEFAULT_MAX_READ_BYTES)))
        size = target.stat().st_size
        if size > limit:
            raise ValueError(f'文件过大: {size} bytes，超过读取上限 {limit} bytes')
        return target.read_text(encoding='utf-8')
