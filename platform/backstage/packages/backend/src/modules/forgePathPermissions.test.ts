import {
  AuthorizeResult,
  createPermission,
} from '@backstage/plugin-permission-common';
import { actionExecutePermission } from '@backstage/plugin-scaffolder-common/alpha';
import { ForgePathPermissionPolicy } from './forgePathPermissions';

describe('ForgePathPermissionPolicy', () => {
  const policy = new ForgePathPermissionPolicy();

  it('denies direct Kubernetes proxy access', async () => {
    const decision = await policy.handle({
      permission: createPermission({
        name: 'kubernetes.proxy',
        attributes: {},
      }),
    });

    expect(decision).toEqual({ result: AuthorizeResult.DENY });
  });

  it('permits execution of only the ForgePath end-to-end creation action', async () => {
    const decision = await policy.handle({
      permission: actionExecutePermission,
    });

    expect(decision).toMatchObject({
      result: AuthorizeResult.CONDITIONAL,
      pluginId: 'scaffolder',
      resourceType: 'scaffolder-action',
      conditions: {
        rule: 'HAS_ACTION_ID',
        params: { actionId: 'forgepath:createSecureFastapi' },
      },
    });
  });
});
