import {createHash} from 'node:crypto';

function assert(condition,message){if(!condition)throw new Error(message);}
function digest(value){return createHash('sha256').update(JSON.stringify(value)).digest('hex');}
function scalar(value){return typeof value==='string'&&value.length>0&&value.length<=256&&!/[\u0000-\u001f]/u.test(value);}
function unique(values){return new Set(values).size===values.length;}

// Pure, offline expansion. No infrastructure provisioning or implicit authority.
export function planExperiment(spec){
  assert(spec&&typeof spec==='object'&&!Array.isArray(spec),'experiment spec must be an object');
  assert(spec.schema===1,'unsupported experiment schema');
  assert(scalar(spec.name),'name must be a nonempty string of at most 256 characters');
  assert(typeof spec.baselineDigest==='string'&&/^[a-f0-9]{64}$/u.test(spec.baselineDigest),'baselineDigest must be lowercase SHA-256');
  assert(typeof spec.taskDigest==='string'&&/^[a-f0-9]{64}$/u.test(spec.taskDigest),'taskDigest must be lowercase SHA-256');
  const dimensions=spec.dimensions;
  assert(dimensions&&typeof dimensions==='object'&&!Array.isArray(dimensions),'dimensions must be an object');
  const allowed=['model','promptDigest','reasoning'];
  assert(Object.keys(dimensions).length===allowed.length&&allowed.every(k=>Object.hasOwn(dimensions,k)),'exact dimensions required: model, promptDigest, reasoning');
  for(const key of allowed){
    const values=dimensions[key];
    assert(Array.isArray(values)&&values.length>0&&values.length<=32,`${key} requires 1..32 values`);
    assert(values.every(scalar)&&unique(values),`${key} values must be unique, nonempty strings`);
  }
  assert(dimensions.promptDigest.every(v=>/^[a-f0-9]{64}$/u.test(v)),'promptDigest values must be lowercase SHA-256');
  const repetitions=spec.repetitions;
  assert(Number.isSafeInteger(repetitions)&&repetitions>=1&&repetitions<=100,'repetitions must be 1..100');
  const maxRuns=spec.maxRuns;
  assert(Number.isSafeInteger(maxRuns)&&maxRuns>=1&&maxRuns<=10000,'maxRuns must be 1..10000');
  const combinations=allowed.reduce((n,k)=>n*dimensions[k].length,1);
  assert(combinations*repetitions<=maxRuns,'experiment run count exceeds explicit maxRuns');
  const canonical={schema:1,name:spec.name,baselineDigest:spec.baselineDigest,taskDigest:spec.taskDigest,
    dimensions:Object.fromEntries(allowed.map(k=>[k,[...dimensions[k]].sort()])),repetitions,maxRuns};
  const experimentDigest=digest(canonical);
  const runs=[];
  for(const model of canonical.dimensions.model)
    for(const promptDigest of canonical.dimensions.promptDigest)
      for(const reasoning of canonical.dimensions.reasoning)
        for(let repetition=0;repetition<repetitions;repetition++){
          const config={model,promptDigest,reasoning,repetition};
          runs.push({id:digest({experimentDigest,config}),...config});
        }
  return {schema:1,experimentDigest,name:canonical.name,baselineDigest:canonical.baselineDigest,
    taskDigest:canonical.taskDigest,runCount:runs.length,runs,execution:'none',
    note:'Offline plan only. No authorization, spend, execution, or environment replay.'};
}
