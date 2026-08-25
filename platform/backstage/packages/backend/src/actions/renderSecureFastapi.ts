import { execFile } from 'node:child_process';
import { access } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import type { Config } from '@backstage/config';
import { createTemplateAction } from '@backstage/plugin-scaffolder-node';

const execFileAsync = promisify(execFile);
const dnsLabel = /^[a-z][a-z0-9-]{1,61}[a-z0-9]$/;
const ownerRef = /^group:default\/[a-z][a-z0-9-]{1,61}[a-z0-9]$/;
const repositoryOwner = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/;

function resolveConfiguredPath(base: string, configuredPath: string): string {
  return path.resolve(base, configuredPath);
}

function assertChildPath(parent: string, child: string): void {
  const relative = path.relative(parent, child);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`refusing path outside configured root: ${child}`);
  }
}

export function createRenderSecureFastapiAction(config: Config) {
  const processRoot = process.cwd();
  const repositoryRoot = resolveConfiguredPath(
    processRoot,
    config.getString('forgepath.repositoryRoot'),
  );
  const generationRoot = resolveConfiguredPath(
    processRoot,
    config.getString('forgepath.generationRoot'),
  );
  const pythonExecutable = config.getString('forgepath.pythonExecutable');
  const simulationRoot = resolveConfiguredPath(
    processRoot,
    config.getString('forgepath.simulationRoot'),
  );
  const allowedOwners = config.getStringArray('forgepath.allowedOwners');
  const allowedSystems = config.getStringArray('forgepath.allowedSystems');
  const allowedRepositoryOwners = config.getStringArray(
    'forgepath.allowedRepositoryOwners',
  );
  const gitopsRepository = config.getString('forgepath.gitopsRepository');
  const githubCodeowner = config.getString('forgepath.githubCodeowner');
  const catalogApiUrl = config.getString('forgepath.catalogApiUrl');
  const renderer = path.join(
    repositoryRoot,
    'templates/secure-fastapi-service/render.py',
  );
  const publisher = path.join(
    repositoryRoot,
    'templates/secure-fastapi-service/publish.py',
  );
  assertChildPath(repositoryRoot, renderer);
  assertChildPath(repositoryRoot, publisher);
  assertChildPath(repositoryRoot, generationRoot);
  assertChildPath(repositoryRoot, simulationRoot);

  return createTemplateAction({
    id: 'forgepath:createSecureFastapi',
    description:
      'Validates, renders, and safely publishes the secure FastAPI paved path.',
    examples: [
      {
        description: 'Generate and locally simulate publication of a service.',
        example: `steps:
  - id: createService
    action: forgepath:createSecureFastapi
    input:
      name: example-api
      owner: group:default/platform
      system: forgepath
      environment: development
      dataClassification: internal
      publishMode: local
      repositoryOwner: SecureCloudOps
`,
      },
    ],
    schema: {
      input: {
        name: z => z.string().regex(dnsLabel),
        owner: z => z.string().regex(ownerRef),
        system: z => z.string().regex(dnsLabel),
        environment: z =>
          z.enum(['local', 'development', 'staging', 'production']),
        dataClassification: z =>
          z.enum(['public', 'internal', 'confidential', 'restricted']),
        publishMode: z => z.enum(['local', 'github']),
        repositoryOwner: z => z.string().regex(repositoryOwner),
        imageRepository: z => z.string().optional(),
        privileged: z => z.boolean().default(false),
      },
      output: {
        localPath: z => z.string(),
        catalogInfoPath: z => z.string(),
        techdocsPath: z => z.string(),
        publication: z => z.string(),
        serviceRepository: z => z.string(),
        servicePullRequest: z => z.string(),
        gitopsPullRequest: z => z.string(),
      },
    },
    async handler(ctx) {
      await access(renderer);
      await access(publisher);
      if (!allowedOwners.includes(ctx.input.owner)) {
        throw new Error('owner is not an allowlisted Backstage Group entity');
      }
      if (!allowedSystems.includes(ctx.input.system)) {
        throw new Error('system is not an allowlisted Backstage System entity');
      }
      if (
        !allowedRepositoryOwners.some(
          allowed =>
            allowed.toLocaleLowerCase('en-US') ===
            ctx.input.repositoryOwner.toLocaleLowerCase('en-US'),
        )
      ) {
        throw new Error('repository target is not allowlisted');
      }
      if (ctx.input.privileged) {
        throw new Error('privileged access is not supported by this paved path');
      }
      if (
        gitopsRepository.toLocaleLowerCase('en-US') !==
        `${ctx.input.repositoryOwner}/forgepath-gitops`.toLocaleLowerCase('en-US')
      ) {
        throw new Error('configured GitOps repository is outside the allowlisted target');
      }
      if (
        !githubCodeowner
          .toLocaleLowerCase('en-US')
          .startsWith(`${ctx.input.repositoryOwner}/`.toLocaleLowerCase('en-US'))
      ) {
        throw new Error('configured CODEOWNER is outside the allowlisted target');
      }
      const expectedImageRepository = `ghcr.io/${ctx.input.repositoryOwner.toLocaleLowerCase(
        'en-US',
      )}/${ctx.input.name}`;
      if (
        ctx.input.imageRepository !== undefined &&
        ctx.input.imageRepository !== expectedImageRepository
      ) {
        throw new Error(
          `unsupported image configuration; expected ${expectedImageRepository}`,
        );
      }
      const identity = ctx.user?.ref ?? 'user:default/guest';
      if (ctx.input.publishMode === 'github') {
        if (/^user:[^/]+\/guest$/.test(identity)) {
          throw new Error(
            'GitHub publication requires an authenticated non-guest Backstage identity',
          );
        }
        if (!process.env.FORGEPATH_GITHUB_APP_TOKEN) {
          throw new Error('GitHub App installation token is not configured');
        }
        if (!process.env.FORGEPATH_BACKSTAGE_CATALOG_TOKEN) {
          throw new Error('Backstage catalog registration token is not configured');
        }
      }

      const output = path.join(generationRoot, ctx.input.name);
      assertChildPath(generationRoot, output);
      const namespace = `${ctx.input.name}-${ctx.input.environment}`;
      if (!dnsLabel.test(namespace)) {
        throw new Error('derived Kubernetes namespace exceeds the DNS-label limit');
      }

      const { stdout, stderr } = await execFileAsync(
        pythonExecutable,
        [
          renderer,
          '--output',
          output,
          '--service-name',
          ctx.input.name,
          '--description',
          `Secure FastAPI service ${ctx.input.name}, generated by ForgePath.`,
          '--owner',
          ctx.input.owner,
          '--system',
          ctx.input.system,
          '--environment',
          ctx.input.environment,
          '--data-classification',
          ctx.input.dataClassification,
          '--image-repository',
          expectedImageRepository,
          '--github-codeowner',
          githubCodeowner,
          '--gitops-repository',
          gitopsRepository,
          '--kubernetes-namespace',
          namespace,
        ],
        { cwd: repositoryRoot, maxBuffer: 1024 * 1024 },
      );
      if (stdout.trim()) {
        ctx.logger.info(stdout.trim());
      }
      if (stderr.trim()) {
        ctx.logger.warn(stderr.trim());
      }

      const publisherArguments = [
        publisher,
        '--mode',
        ctx.input.publishMode,
        '--source',
        output,
        '--generation-root',
        generationRoot,
        '--simulation-root',
        simulationRoot,
        '--service-name',
        ctx.input.name,
        '--owner',
        ctx.input.owner,
        '--system',
        ctx.input.system,
        '--environment',
        ctx.input.environment,
        '--data-classification',
        ctx.input.dataClassification,
        '--repository-owner',
        ctx.input.repositoryOwner,
        '--gitops-repository',
        gitopsRepository,
        '--backstage-identity',
        identity,
        '--backstage-catalog-url',
        catalogApiUrl,
      ];
      for (const allowed of allowedOwners) {
        publisherArguments.push('--allowed-owner', allowed);
      }
      for (const allowed of allowedSystems) {
        publisherArguments.push('--allowed-system', allowed);
      }
      for (const allowed of allowedRepositoryOwners) {
        publisherArguments.push('--allowed-repository-owner', allowed);
      }
      const published = await execFileAsync(pythonExecutable, publisherArguments, {
        cwd: repositoryRoot,
        env: process.env,
        maxBuffer: 1024 * 1024,
      });
      if (published.stderr.trim()) {
        ctx.logger.warn(published.stderr.trim());
      }
      const publication = JSON.parse(published.stdout.trim()) as {
        serviceRepository: string;
        servicePullRequest: string | { head: string };
        gitopsPullRequest: string | { head: string };
      };

      ctx.output('localPath', output);
      ctx.output('catalogInfoPath', path.join(output, 'catalog-info.yaml'));
      ctx.output('techdocsPath', path.join(output, 'docs'));
      ctx.output('publication', published.stdout.trim());
      ctx.output('serviceRepository', publication.serviceRepository);
      ctx.output(
        'servicePullRequest',
        typeof publication.servicePullRequest === 'string'
          ? publication.servicePullRequest
          : publication.servicePullRequest.head,
      );
      ctx.output(
        'gitopsPullRequest',
        typeof publication.gitopsPullRequest === 'string'
          ? publication.gitopsPullRequest
          : publication.gitopsPullRequest.head,
      );
      ctx.logger.info(
        `Created ${ctx.input.name} through the ${ctx.input.publishMode} paved path`,
      );
    },
  });
}
