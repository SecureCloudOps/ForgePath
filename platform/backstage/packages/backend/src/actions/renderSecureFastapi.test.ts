import { access, mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { ConfigReader } from '@backstage/config';
import { createMockActionContext } from '@backstage/plugin-scaffolder-node-test-utils';
import { createRenderSecureFastapiAction } from './renderSecureFastapi';

describe('forgepath:createSecureFastapi', () => {
  it('validates, renders, and simulates safe publication locally', async () => {
    const repositoryRoot = path.resolve(process.cwd(), '../../../..');
    await mkdir(path.join(repositoryRoot, '.forgepath'), { recursive: true });
    const generationRoot = await mkdtemp(
      path.join(repositoryRoot, '.forgepath/backstage-action-test.'),
    );
    const simulationRoot = await mkdtemp(
      path.join(repositoryRoot, '.forgepath/backstage-publish-test.'),
    );
    const serviceName = 'secure-fastapi-service';
    const output = path.join(generationRoot, serviceName);

    try {
      const action = createRenderSecureFastapiAction(
        new ConfigReader({
          forgepath: {
            repositoryRoot,
            generationRoot,
            simulationRoot,
            pythonExecutable: 'python3.12',
            allowedOwners: ['group:default/platform'],
            allowedSystems: ['forgepath'],
            allowedRepositoryOwners: ['SecureCloudOps'],
            gitopsRepository: 'SecureCloudOps/forgepath-gitops',
            githubCodeowner: 'SecureCloudOps/platform',
            catalogApiUrl: 'http://localhost:7007/api/catalog',
          },
        }),
      );
      const context = createMockActionContext({
        input: {
          name: serviceName,
          owner: 'group:default/platform',
          system: 'forgepath',
          environment: 'local' as const,
          dataClassification: 'internal' as const,
          publishMode: 'local' as const,
          repositoryOwner: 'SecureCloudOps',
          privileged: false,
        },
      });

      await action.handler(context);

      expect(context.output).toHaveBeenCalledWith('localPath', output);
      expect(context.output).toHaveBeenCalledWith(
        'servicePullRequest',
        'forgepath/enable-delivery',
      );
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
      expect(
        await readFile(
          path.join(simulationRoot, serviceName, 'publication.json'),
          'utf8',
        ),
      ).toContain('"securityControlsInherited": 9');
    } finally {
      await rm(generationRoot, { recursive: true, force: true });
      await rm(simulationRoot, { recursive: true, force: true });
    }
  });

  it('rejects an unauthorized repository before creating output', async () => {
    const repositoryRoot = path.resolve(process.cwd(), '../../../..');
    const generationRoot = await mkdtemp(
      path.join(repositoryRoot, '.forgepath/backstage-action-denial-test.'),
    );
    const simulationRoot = await mkdtemp(
      path.join(repositoryRoot, '.forgepath/backstage-publish-denial-test.'),
    );
    try {
      const action = createRenderSecureFastapiAction(
        new ConfigReader({
          forgepath: {
            repositoryRoot,
            generationRoot,
            simulationRoot,
            pythonExecutable: 'python3.12',
            allowedOwners: ['group:default/platform'],
            allowedSystems: ['forgepath'],
            allowedRepositoryOwners: ['SecureCloudOps'],
            gitopsRepository: 'SecureCloudOps/forgepath-gitops',
            githubCodeowner: 'SecureCloudOps/platform',
            catalogApiUrl: 'http://localhost:7007/api/catalog',
          },
        }),
      );
      const context = createMockActionContext({
        input: {
          name: 'unsafe-target',
          owner: 'group:default/platform',
          system: 'forgepath',
          environment: 'development' as const,
          dataClassification: 'internal' as const,
          publishMode: 'local' as const,
          repositoryOwner: 'UntrustedOrg',
          privileged: false,
        },
      });
      await expect(action.handler(context)).rejects.toThrow(
        'repository target is not allowlisted',
      );
      await expect(access(path.join(generationRoot, 'unsafe-target'))).rejects.toThrow();
    } finally {
      await rm(generationRoot, { recursive: true, force: true });
      await rm(simulationRoot, { recursive: true, force: true });
    }
  });
});
