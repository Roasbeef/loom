"""Fixed-affinity selected-session CPU/memory experiment; scratch diagnostics.

Warm attach keeps the fixture daemon/session resident. Cold autostart first
creates a real saved session and closes its daemon, then times the real client
launch through daemon replacement and the attached composer. Fixture seeding
and durable input-admission checks are outside the timing endpoint.
"""
import argparse
from contextlib import closing
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import signal
import statistics
import time

REPO=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('bench',REPO/'scripts/bench_startup_memory.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
b.BEST_EFFORT=True
BASE=REPO/'build/bench-startup-memory/releases/startup-overlap-baseline'
CURRENT=REPO/'build/release'
RUN_LABEL='client-resource'
EXPECTED_AFFINITY=None
CLOCK_TICKS=os.sysconf('SC_CLK_TCK')


class ResourceClient(b.Client):
    """Preserve real PTY behavior and retain the same wait4 resource record."""
    def stop(self):
        try:
            os.kill(self.pid,signal.SIGKILL)
        except ProcessLookupError:
            pass
        while True:
            reaped,_,usage=os.wait4(self.pid,os.WNOHANG)
            if reaped==self.pid:break
            self._read(.01)
        b.LIVE.discard(self.pid)
        os.close(self.fd)
        self.wait4_cpu={'user_ms':usage.ru_utime*1000,'system_ms':usage.ru_stime*1000,
                        'total_ms':(usage.ru_utime+usage.ru_stime)*1000,
                        'elapsed_ms':b.now_ms()-self.started}
        return b.maxrss_kib(usage.ru_maxrss)


def proc_resources(pid):
    """Linux process totals; child counters cover only already-waited children."""
    fields=Path('/proc/%d/stat'%pid).read_text().rsplit(')',1)[1].split()
    assert fields[0]!='Z'
    counters={key:int(fields[index])for key,index in [('utime',11),('stime',12),('cutime',13),('cstime',14)]}
    status={line.split(':',1)[0]:line.split(':',1)[1].strip()for line in Path('/proc/%d/status'%pid).read_text().splitlines()if ':'in line}
    return {'pid':pid,'parent_pid':int(fields[1]),'start_ticks':int(fields[19]),
            'ticks':counters,'own_cpu_ms':1000*(counters['utime']+counters['stime'])/CLOCK_TICKS,
            'waited_child_cpu_ms':1000*(counters['cutime']+counters['cstime'])/CLOCK_TICKS,
            'cpu_with_waited_children_ms':1000*sum(counters.values())/CLOCK_TICKS,
            'rss_kib':int(status['VmRSS'].split()[0]),'hwm_kib':int(status['VmHWM'].split()[0])}


def cgroup_snapshot():
    """Dedicated container totals include helpers and this observer's work."""
    cpu={key:int(value)for key,value in (line.split()for line in Path('/sys/fs/cgroup/cpu.stat').read_text().splitlines())}
    return {'cpu':cpu,'memory_current_bytes':int(Path('/sys/fs/cgroup/memory.current').read_text()),
            'memory_peak_cumulative_bytes':int(Path('/sys/fs/cgroup/memory.peak').read_text())}


def process_lineage(pid):
    lineage=[]
    while pid>0:
        fields=Path('/proc/%d/stat'%pid).read_text().rsplit(')',1)[1].split()
        lineage.append({'pid':pid,'parent_pid':int(fields[1]),'start_ticks':int(fields[19])})
        pid=int(fields[1])
    return lineage


def verify_affinity(pid):
    observed={tuple(sorted(os.sched_getaffinity(int(task.name))))for task in Path('/proc/%d/task'%pid).iterdir()}
    assert observed=={EXPECTED_AFFINITY},(pid,observed,EXPECTED_AFFINITY)
    return list(EXPECTED_AFFINITY)


def native_identity(profile,build,expected_pid=None):
    record=json.loads(Path(profile.state,'daemon.endpoint').read_text())
    pid=record['pid']
    if expected_pid is not None:assert pid==expected_pid
    stat=Path('/proc/%d/stat'%pid).read_text()
    fields=stat.rsplit(')',1)[1].split()
    assert fields[0]!='Z'
    birth='linux:'+Path('/proc/sys/kernel/random/boot_id').read_text().strip()+':'+fields[19]
    assert birth==record['birth']
    executable=Path('/proc/%d/exe'%pid).resolve()
    expected_executables=[p.resolve()for p in Path(build.loomd).parent.parent.glob('erts-*/bin/beam.smp')]
    assert executable in expected_executables,(executable,expected_executables)
    command=Path('/proc/%d/cmdline'%pid).read_bytes().split(b'\0')
    assert b'--state-dir'in command and profile.state.encode()in command
    return {'pid':pid,'birth':birth,'executable':str(executable),'epoch':record['epoch'],
            'command':[arg.decode(errors='replace')for arg in command if arg]}


def input_admitted(client,db,sentinel):
    """Prove a new durable user turn, rather than matching terminal echo."""
    with closing(sqlite3.connect(db.as_uri()+'?mode=ro',uri=True,timeout=.2))as conn:
        before=conn.execute('select coalesce(max(seq),0) from entries').fetchone()[0]
    os.write(client.fd,sentinel.encode()+b'\r')
    deadline=time.monotonic()+10
    while time.monotonic()<deadline:
        client.drain(.01)
        try:
            with closing(sqlite3.connect(db.as_uri()+'?mode=ro',uri=True,timeout=.2))as conn:
                rows=conn.execute('select seq,payload from entries where seq>? and type=? order by seq',(before,'message')).fetchall()
        except sqlite3.OperationalError:
            continue
        for seq,payload in rows:
            entry=json.loads(payload)
            message=entry.get('message',{})
            content=message.get('content',[])
            if message.get('role')=='user'and any(isinstance(block,dict)and block.get('type')=='text'and block.get('text')==sentinel for block in content):
                return {'before_seq':before,'admitted_seq':seq,'durable_user_turn':True}
    raise b.BenchError('post-timing PTY input did not produce a durable user turn')


def trial(mode,pair,fixture,workload,warmup=False):
    b.CONFIG=str(REPO/('scripts/release-smoke.toml'if fixture=='smoke'else'build/startup/models32.toml'))
    build=b.Build(mode,str(BASE if mode=='baseline'else CURRENT));build.check()
    name='%s-%s-%s-%s-%s'%(RUN_LABEL,fixture,workload,pair,mode)
    profile=b.Profile(name)
    d=None;control=None;client=None;foreign=None;setup_fence=None;retired=False
    try:
        # Both fixtures use the real daemon/control protocol to seed the same
        # private catalogue and session; neither fabricates SQLite ownership.
        d=b.Daemon(profile,build);control=b.Control(profile,d.port)
        timed=control.create_session_timed(profile,'client-overlap-fixture')
        ident=timed['session_id'];setup_fence=native_identity(profile,build,d.proc.pid)
        control.close();control=None
        if workload=='cold-autostart':
            d.stop();d=None
            assert 'daemon.stopped'in Path(profile.root,'loomd.log').read_text()
        daemon_before=proc_resources(d.proc.pid)if d is not None else None
        cgroup_before=cgroup_snapshot()
        client=ResourceClient(profile,build,b.client_args(profile,build,'--session',ident))
        first=client.await_first_frame();composer=client.await_text(b.ATTACHED)
        # CPU/memory are sampled immediately after timestamping the composer,
        # before input, native-fence verification, or affinity enumeration.
        cgroup_at_composer=cgroup_snapshot()
        client_at_composer=proc_resources(client.pid)
        endpoint_record=json.loads(Path(profile.state,'daemon.endpoint').read_text())
        daemon_at_composer=proc_resources(endpoint_record['pid'])
        sample_gap_ms=b.now_ms()-client.started-composer
        daemon_cpu=daemon_at_composer['cpu_with_waited_children_ms']-(daemon_before['cpu_with_waited_children_ms']if daemon_before else 0)
        assert daemon_cpu>=0
        # A live daemon has not been waited/reaped, so its own counters are
        # not in the client's cutime/cstime; count this separate live branch once.
        fence=native_identity(profile,build,None if d is None else d.proc.pid)
        assert daemon_at_composer['start_ticks']==int(fence['birth'].rsplit(':',1)[1])
        if daemon_before is not None:assert daemon_before['start_ticks']==daemon_at_composer['start_ticks']
        if workload=='cold-autostart':
            assert (fence['pid'],fence['birth'])!=(setup_fence['pid'],setup_fence['birth'])
            foreign=fence['pid']
        row={'mode':mode,'pair':pair,'fixture':fixture,'workload':workload,'warmup':warmup,
             'first_frame_ms':first,'composer_ms':composer,'native_identity':fence,
             'client_at_composer':client_at_composer,'daemon_at_composer':daemon_at_composer,
             'cgroup_before_client':cgroup_before,'cgroup_at_composer':cgroup_at_composer,
             'cgroup_composer_cpu_ms':(cgroup_at_composer['cpu']['usage_usec']-cgroup_before['cpu']['usage_usec'])/1000,
             'client_lineage':process_lineage(client.pid),'daemon_lineage':process_lineage(fence['pid']),
             'client_command':[arg.decode(errors='replace')for arg in Path('/proc/%d/cmdline'%client.pid).read_bytes().split(b'\0')if arg],
             'daemon_before_client':daemon_before,'daemon_interval_cpu_ms':daemon_cpu,
             'client_composer_cpu_ms':client_at_composer['cpu_with_waited_children_ms'],
             'combined_composer_cpu_ms':client_at_composer['cpu_with_waited_children_ms']+daemon_cpu,
             'combined_composer_rss_kib':client_at_composer['rss_kib']+daemon_at_composer['rss_kib'],
             'resource_sample_gap_ms':sample_gap_ms,
             'client_affinity':verify_affinity(client.pid),'daemon_affinity':verify_affinity(fence['pid']),
             'daemon_rss_kib':b.ps_rss_kib(fence['pid']),'session_id':ident,
             'profile_root':profile.root,'seed_identity':setup_fence}
        sentinel='startup admission %s %s %s %s'%(fixture,workload,pair,mode)
        row['input_admission']=input_admitted(client,Path(profile.state,'sessions',ident+'.db'),sentinel)
        row['client_peak_rss_kib']=client.stop()
        row['client_whole_fixture_wait4_cpu']=client.wait4_cpu
        client=None
        if d is not None:
            row['daemon_peak_rss_kib']=d.stop();d=None
            log=Path(profile.root,'loomd.log').read_text()
        else:
            # The bootstrap child is not this Python process's child. Verify
            # the native fence immediately before using the existing cleanup.
            assert native_identity(profile,build,foreign)['birth']==fence['birth']
            b.stop_foreign(foreign);foreign=None
            log=Path(profile.state,'daemon.log').read_text()
        assert 'daemon.stopped'in log
        assert 'daemon.retirement_unconfirmed'not in log
        retired=True
        row['normal_daemon_shutdown']=True
        print(json.dumps(row),flush=True)
        return row
    finally:
        if client is not None:client.stop()
        if control is not None:control.close()
        if d is not None:d.stop()
        elif foreign is not None:b.stop_foreign(foreign)
        elif workload=='cold-autostart'and not retired:
            # Constructor/startup failures may precede the successful endpoint
            # check. Only a live, matching fixture executable/fence is ours.
            try:
                fence=native_identity(profile,build)
                if setup_fence is None or (fence['pid'],fence['birth'])!=(setup_fence['pid'],setup_fence['birth']):
                    b.stop_foreign(fence['pid'])
            except (FileNotFoundError,ProcessLookupError):
                pass
        # Retain failed-run logs; successful runs also remain for audit. They
        # contain only generated fixtures and never operator state.


def artifact_fingerprint(root):
    """Record immutable release contents outside all timed intervals."""
    digest=hashlib.sha256();files=0
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            payload=('symlink:'+os.readlink(path)).encode()
        elif path.is_file():
            payload=hashlib.sha256(path.read_bytes()).digest()
        else:
            continue
        digest.update(str(path.relative_to(root)).encode()+b'\0'+str(path.lstat().st_mode).encode()+b'\0'+payload+b'\0')
        files+=1
    return {'sha256':digest.hexdigest(),'files':files}


def main():
    global RUN_LABEL,EXPECTED_AFFINITY,BASE,CURRENT
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runs',type=int,default=7)
    parser.add_argument('--configs',default='smoke,models32')
    parser.add_argument('--workloads',default='warm-attach,cold-autostart')
    parser.add_argument('--label',default='client-resource')
    parser.add_argument('--cores',type=int,default=1)
    parser.add_argument('--baseline',type=Path,default=BASE)
    parser.add_argument('--candidate',type=Path,default=CURRENT)
    parser.add_argument('--allow-server-difference',action='store_true')
    args=parser.parse_args()
    RUN_LABEL=args.label
    BASE=args.baseline.resolve()
    CURRENT=args.candidate.resolve()
    allowed=sorted(os.sched_getaffinity(0))
    assert 0<args.cores<=len(allowed)
    EXPECTED_AFFINITY=tuple(allowed[:args.cores])
    os.sched_setaffinity(0,EXPECTED_AFFINITY)
    assert args.runs>0
    assert set(args.configs.split(','))<={'smoke','models32'}
    assert set(args.workloads.split(','))<={'warm-attach','cold-autostart'}
    artifacts={mode:{part:artifact_fingerprint(root/part)for part in ['loom','loom-client']}
               for mode,root in [('baseline',BASE),('candidate',CURRENT)]}
    assert args.allow_server_difference or artifacts['baseline']['loom']==artifacts['candidate']['loom'],'server release changed in a client-only comparison'
    rows=[]
    for fixture in args.configs.split(','):
        for workload in args.workloads.split(','):
            for mode in ['baseline','candidate']:
                rows.append(trial(mode,'warmup',fixture,workload,True))
                (REPO/'build/startup'/(args.label+'-partial.json')).write_text(json.dumps(rows,indent=2))
            for pair in range(args.runs):
                for mode in (['baseline','candidate']if pair%2==0 else['candidate','baseline']):
                    rows.append(trial(mode,pair,fixture,workload))
                    (REPO/'build/startup'/(args.label+'-partial.json')).write_text(json.dumps(rows,indent=2))
    assert artifacts=={mode:{part:artifact_fingerprint(root/part)for part in ['loom','loom-client']}
                       for mode,root in [('baseline',BASE),('candidate',CURRENT)]},'release changed during measurement'
    provenance={'affinity':list(EXPECTED_AFFINITY),'original_allowed_cpus':allowed,'clock_ticks_per_second':CLOCK_TICKS,
                'cgroup_semantics':'Dedicated container cpu.stat delta from immediately before client fork to immediately after composer, including harness and helpers. memory.peak is cumulative for this container, not a per-trial startup peak.',
                'cpu_semantics':'Client and separate live daemon process utime+stime+cutime+cstime at composer. Warm daemon subtracts snapshot immediately before client launch; cold daemon is replacement lifetime. Child counters include only waited children; live helper CPU is not a process-tree census. Client wait4 is separately reported through post-timing durable admission and termination.',
                'memory_semantics':'VmRSS and VmHWM sampled at composer, per process. Warm daemon HWM includes fixture seeding. Client wait4 peak includes post-timing admission. No claim of simultaneous combined peak.',
                'allow_server_difference':args.allow_server_difference,'artifacts':artifacts,'baseline':str(BASE),'candidate':str(CURRENT),'runs':args.runs,'best_effort':True,
                'cold_fixture':'real saved session and catalogue; fixture daemon stopped before timed client autostart',
                'endpoint':'real selected-session attached composer; first frame recorded separately',
                'input_admission':'PTY prompt committed as new durable user-turn entry after timer; unreachable synthetic provider',
                'configs':{f:b.configuration_provenance(str(REPO/('scripts/release-smoke.toml'if f=='smoke'else'build/startup/models32.toml')))for f in args.configs.split(',')}}
    out=REPO/'build/startup'/(args.label+'-results.json')
    out.write_text(json.dumps({'provenance':provenance,'rows':rows},indent=2))
    for fixture in args.configs.split(','):
        for workload in args.workloads.split(','):
            rs=[r for r in rows if r['fixture']==fixture and r['workload']==workload and not r['warmup']]
            for key in ['first_frame_ms','composer_ms','cgroup_composer_cpu_ms','combined_composer_cpu_ms','combined_composer_rss_kib','client_peak_rss_kib']:
                values={m:[r[key]for r in rs if r['mode']==m]for m in ['baseline','candidate']}
                paired=[a-z for a,z in zip(values['baseline'],values['candidate'])]
                print(fixture,workload,key,{m:statistics.median(v)for m,v in values.items()},'paired_savings',paired,flush=True)
    print('Wrote',out,flush=True)

if __name__=='__main__':main()
