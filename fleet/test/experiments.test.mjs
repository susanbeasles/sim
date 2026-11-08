import {test} from 'node:test';
import assert from 'node:assert/strict';
import {planExperiment} from '../src/experiments.mjs';

const hash=n=>String(n).repeat(64);
const spec=()=>({schema:1,name:'same-task-model-comparison',baselineDigest:hash('a'),taskDigest:hash('b'),
  dimensions:{model:['qwen-3b','codex'],promptDigest:[hash('c'),hash('d')],reasoning:['low','high']},
  repetitions:3,maxRuns:24});

test('expands a bounded factorial experiment with unique deterministic run IDs',()=>{
  const a=planExperiment(spec()),b=planExperiment(spec());
  assert.deepEqual(a,b);
  assert.equal(a.runCount,24);
  assert.equal(new Set(a.runs.map(r=>r.id)).size,24);
  assert.equal(a.execution,'none');
  assert.equal(a.runs.filter(r=>r.model==='qwen-3b').length,12);
});

test('input permutation does not change experiment identity',()=>{
  const s=spec(),a=planExperiment(s);
  s.dimensions.model.reverse();s.dimensions.promptDigest.reverse();s.dimensions.reasoning.reverse();
  assert.deepEqual(planExperiment(s),a);
});

test('rejects runs without an explicit bounded budget',()=>{
  const s=spec();s.maxRuns=23;
  assert.throws(()=>planExperiment(s),/exceeds explicit maxRuns/);
  s.maxRuns=24;s.repetitions=101;
  assert.throws(()=>planExperiment(s),/repetitions/);
});

test('rejects malformed hashes, unknown dimensions, repeated values and invalid schemas',()=>{
  for(const edit of [
    s=>{s.schema=2;},s=>{s.baselineDigest='oops';},s=>{s.dimensions.promptDigest=['../escape'];},
    s=>{s.dimensions.model=['same','same'];},s=>{s.dimensions.tools=['shell'];},
    s=>{s.repetitions=0;},s=>{s.name='';}
  ]){const s=spec();edit(s);assert.throws(()=>planExperiment(s));}
});

test('digest binds the underlying task, baseline, and run parameters',()=>{
  const s=spec(),before=planExperiment(s);
  s.taskDigest=hash('e');
  assert.notEqual(planExperiment(s).experimentDigest,before.experimentDigest);
  s.taskDigest=hash('b');s.dimensions.reasoning=['low'];
  assert.notEqual(planExperiment(s).experimentDigest,before.experimentDigest);
});
