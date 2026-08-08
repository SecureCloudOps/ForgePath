import { execFile } from 'node:child_process';
import { access } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import type { Config } from '@backstage/config';
import { createTemplateAction } from '@backstage/plugin-scaffolder-node';

const execFileAsync = promisify(execFile);
const dnsLabel = /^[a-z][a-z0-9-]{1,61}[a-z0-9]$/;

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
  const renderer = path.join(
    repositoryRoot,
    'templates/secure-fastapi-service/render.py',
  );
  assertChildPath(repositoryRoot, renderer);
  assertChildPath(repositoryRoot, generationRoot);

  return createTemplateAction({
    id: 'forgepath:renderSecureFastapi',
    description:
      'Runs the repository-owned secure-fastapi-service renderer into a local output root.',
    examples: [
      {
        description: 'Generate a local service without publishing it.',
        example: `steps:
  - id: generateLocal
    action: forgepath:renderSecureFastapi
    input:
      name: example-api
      description: Example API
      owner: group:default/platform
      kubernetesNamespace: example-api-local
`,
      },
    ],
    schema: {
      input: {
        name: z => z.string().regex(dnsLabel),
        description: z => z.string().min(1).max(300),
        owner: z => z.string().min(1).max(200),
        kubernetesNamespace: z => z.string().regex(dnsLabel),
      },
      output: {
        localPath: z => z.string(),
        catalogInfoPath: z => z.string(),
        techdocsPath: z => z.string(),
      },
    },
    async handler(ctx) {
      await access(renderer);
      const output = path.join(generationRoot, ctx.input.name);
      assertChildPath(generationRoot, output);

      const { stdout, stderr } = await execFileAsync(
        pythonExecutable,
        [
          renderer,
          '--output',
          output,
          '--service-name',
          ctx.input.name,
          '--description',
          ctx.input.description,
          '--owner',
          ctx.input.owner,
          '--kubernetes-namespace',
          ctx.input.kubernetesNamespace,
        ],
        { cwd: repositoryRoot, maxBuffer: 1024 * 1024 },
      );
      if (stdout.trim()) {
        ctx.logger.info(stdout.trim());
      }
      if (stderr.trim()) {
        ctx.logger.warn(stderr.trim());
      }

      ctx.output('localPath', output);
      ctx.output('catalogInfoPath', path.join(output, 'catalog-info.yaml'));
      ctx.output('techdocsPath', path.join(output, 'docs'));
      ctx.logger.info(`Generated ${ctx.input.name} locally at ${output}`);
    },
  });
}
