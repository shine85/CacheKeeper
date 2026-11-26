"""Run the authorized static batch, or prepare a local five-app evidence report."""
import argparse
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from device_collection_batch import collect,load_resume_parent,resume


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--transport-adapter',type=Path,
                        help='Existing persistent_device_ssh.py; reads its authenticated session without reconnecting.')
    mode=parser.add_mutually_exclusive_group()
    mode.add_argument('--resume',type=Path,help='Terminal collection.json; collect only explicitly unattempted SDK metadata.')
    mode.add_argument('--prepare-session',type=Path,help='Offline only: prepare a five-app report ZIP from terminal collection.json.')
    parser.add_argument('--output',type=Path,help='New ZIP path; required only with --prepare-session.')
    parser.add_argument('--diagnostics',type=Path,help='Saved diagnostic JSON to analyze in the offline session.')
    parser.add_argument('--baseline-diagnostics',type=Path,help='Previous saved diagnostic JSON; requires --diagnostics.')
    args=parser.parse_args(argv)
    if args.prepare_session:
        if args.output is None or args.transport_adapter is not None:
            parser.error('--prepare-session requires --output and cannot use --transport-adapter')
        if args.baseline_diagnostics and not args.diagnostics:
            parser.error('--baseline-diagnostics requires --diagnostics')
        from device_collection_session import prepare_session
        try:summary=prepare_session(args.prepare_session,args.output,
                                    diagnostics_path=args.diagnostics,baseline_path=args.baseline_diagnostics)
        except (OSError,ValueError) as error:
            print(json.dumps(dict(state='sessionPreparationFailed',errorType=type(error).__name__),ensure_ascii=False),file=sys.stderr)
            return 2
        print(json.dumps(summary,ensure_ascii=False,indent=2))
        return 0
    if args.output is not None or args.diagnostics is not None or args.baseline_diagnostics is not None:
        parser.error('--output and diagnostic inputs are only valid with --prepare-session')
    if args.resume:
        try:load_resume_parent(args.resume)
        except (OSError,ValueError) as error:
            print(json.dumps(dict(state='resumeParentRejected',errorType=type(error).__name__),ensure_ascii=False),file=sys.stderr)
            return 2
    from device_collection_transport import QueueTasks,load_transport
    try:
        tasks=QueueTasks(load_transport(args.transport_adapter))
    except (OSError,ImportError,ValueError,RuntimeError) as error:
        print(json.dumps(dict(state='collectionTransportUnavailable',errorType=type(error).__name__,
                              action='使用 --transport-adapter 指向已有且已认证的 persistent_device_ssh.py；协议、记忆模块及会话状态保留原目录。本命令未启动 SSH。'),
                         ensure_ascii=False),file=sys.stderr)
        return 2
    try:
        report,path=resume(tasks,args.resume) if args.resume else collect(tasks,ROOT/'packages/采集报告/批次采集',include_sdk=True)
    except (OSError,ValueError) as error:
        print(json.dumps(dict(state='collectionPreparationFailed',errorType=type(error).__name__),ensure_ascii=False),file=sys.stderr)
        return 2
    report_path=path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
    print(json.dumps(dict(state=report['state'],summary=report['summary'],report=report_path.as_posix(),
                         runtimeExecuted=False),ensure_ascii=False,indent=2))
    return 0 if report['state'] in ('metadataComplete','declaredStaticScopeComplete','sdkResumeComplete') else 2


if __name__=='__main__':raise SystemExit(main())
