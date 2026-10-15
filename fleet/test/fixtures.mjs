import { digest } from '../src/canonical.mjs';
export function configuration() {
  return { schema: 1, fleet: 'test-fleet', project: 'test-project', region: 'us-central1', zones: ['us-central1-a'],
    controllerURL: 'https://10.1.0.2:7660', gatewayURL: 'https://10.1.0.3:7661',
    audience: 'https://sim.example.invalid/fleet', adminSubjects: ['12345'], workerSubject: '67890', gatewaySubject: '13579',
    template: 'projects/test-project/global/instanceTemplates/sim-release-1', releaseDigest: 'a'.repeat(64),
    hardwarePublicKey: 'sk-ssh-ed25519@openssh.com AAAA', workerImage: 'registry.example.invalid/worker@sha256:' + 'b'.repeat(64),
    sandboxTemplate: 'registry.example.invalid/guest@sha256:' + 'c'.repeat(64),
    maxHosts: 10, maxAgents: 200, maxGrantSeconds: 14400, hostCPUs: 32, hostMemoryMiB: 131072,
    reserveMemoryMiB: 28672, cpuOvercommit: 2, idleSeconds: 600, leaseSeconds: 90,
    maxArtifactBytes: 67108864, maxLogBytes: 8388608, hostHourlyMicros: 2000000,
    egressHosts:['deb.debian.org:443','registry.npmjs.org:443'],maxTaskEgressBytes:2147483648,
    maxFleetMicros: 200000000, models: { codex: ['codex-model'], claude: ['claude-model'] },
    profiles: { light: { cpus: 1, memoryMiB: 2048, diskMiB: 10240, maxSeconds: 3600 } } };
}
export function grant(now = 1000) {
  return { schema: 1, id: 'grant-1', fleet: 'test-fleet', nonce: 'n'.repeat(43), issuedAt: now, expiresAt: now + 3600,
    configDigest: digest(configuration()), brokerKeyDigest: 'd'.repeat(64), maxAgents: 200, maxHosts: 4, maxTasks: 200,
    maxCostMicros: 50000000, vendor: 'codex', model: 'codex-model', profile: 'light', args: ['exec','say hello'],
    sourceDigest: 'e'.repeat(64), plaintextDigest: 'f'.repeat(64), keyEnvelope: { opaque: 'encrypted' }, ownerWrap: 'wrapped',
    maxRequests: 20, maxOutputTokens: 4096, taskTTLSeconds: 300 };
}

