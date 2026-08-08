import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { ConfigReader } from '@backstage/config';
import { createMockActionContext } from '@backstage/plugin-scaffolder-node-test-utils';
import { createRenderSecureFastapiAction } from './renderSecureFastapi';

describe('forgepath:renderSecureFastapi', () => {
  it('delegates local generation to the repository paved-path renderer', async () => {
    const repositoryRoot = path.resolve(process.cwd(), '../../../..');
    await mkdir(path.join(repositoryRoot, '.forgepath'), { recursive: true });
    const generationRoot = await mkdtemp(
      path.join(repositoryRoot, '.forgepath/backstage-action-test.'),
    );
    const serviceName = 'secure-fastapi-service';
    const output = path.join(generationRoot, serviceName);

    try {
      const action = createRenderSecureFastapiAction(
        new ConfigReader({
          forgepath: {
            repositoryRoot,
            generationRoot,
            pythonExecutable: 'python3.12',
          },
        }),
      );
      const context = createMockActionContext({
        input: {
          name: serviceName,
          description: 'Backstage contract validation service.',
          owner: 'group:default/platform',
          kubernetesNamespace: 'secure-fastapi-service-local',
        },
      });

      await action.handler(context);

      expect(context.output).toHaveBeenCalledWith('localPath', output);
      expect(context.output).toHaveBeenCalledWith(
        'catalogInfoPath',
        path.join(output, 'catalog-info.yaml'),
      );
      expect(await readFile(path.join(output, 'chart/values.yaml'), 'utf8')).toBe(
        await readFile(
          path.join(
            repositoryRoot,
            'services/secure-fastapi-service/chart/values.yaml',
          ),
          'utf8',
        ),
      );
      const catalog = await readFile(path.join(output, 'catalog-info.yaml'), 'utf8');
      expect(catalog).toContain('owner: group:default/platform');
      expect(catalog).toContain('system: forgepath');
      expect(catalog).toContain(
        'backstage.io/kubernetes-namespace: secure-fastapi-service-local',
      );
      expect(await readFile(path.join(output, 'docs/index.md'), 'utf8')).toContain(
        '# secure-fastapi-service',
      );
    } finally {
      await rm(generationRoot, { recursive: true, force: true });
    }
  });
});
