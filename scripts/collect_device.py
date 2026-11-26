"""Run the authorized static batch on the already authenticated device link."""
import argparse
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from device_collection_batch import collect


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--transport-adapter',type=Path,
                        help='Existing persistent_device_ssh.py; reads its authenticated session without reconnecting.')
    args=parser.parse_args(argv)
    from device_collection_transport import QueueTasks,load_transport
    try:
        tasks=QueueTasks(load_transport(args.transport_adapter))
    except (OSError,ImportError,ValueError,RuntimeError) as error:
        print(json.dumps(dict(state='collectionTransportUnavailable',errorType=type(error).__name__,
                              action='使用 --transport-adapter 指向已有且已认证的 persistent_device_ssh.py；协议、记忆模块及会话状态保留原目录。本命令未启动 SSH。'),
                         ensure_ascii=False),file=sys.stderr)
        return 2
    report,path=collect(tasks,ROOT/'packages/采集报告/批次采集',include_sdk=True)
    print(json.dumps(dict(state=report['state'],summary=report['summary'],report=path.relative_to(ROOT).as_posix(),
                         runtimeExecuted=False),ensure_ascii=False,indent=2))
    return 0 if report['state'] in ('metadataComplete','declaredStaticScopeComplete') else 2


if __name__=='__main__':raise SystemExit(main())
