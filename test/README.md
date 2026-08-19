# Tests

このディレクトリには、テストコードを格納します。
**テストの品質と可読性を統一するため、以下のガイドラインとテンプレートを厳守してください。**

## 1. テスト戦略 (Strategy)
- **TDD (Test-Driven Development) 原則:** 原則として、実装コードを書く前にテストコード（失敗するテスト）を作成してください。
- **Unit Test:** 関数・クラス単体のロジック検証（モックを積極利用）。
- **Integration Test:** データベースやAPIを含む結合動作の検証。
- **E2E Test:** ユーザーシナリオに基づくブラウザ/CLI操作の検証。

## 2. harness↔product 境界とファイル配置
- **root `test/` は harness 所有:** `test/unit/` と `test/integration/` は harness 自己テストの gate であり、harness sync で上書き(managed)されます。製品テストをここに置かないでください。
- **製品テストの配置:** 製品テストは製品コードと同居（`src/**` 配下に `*.test.*` / `*.spec.*` / `__tests__`）させるか、`test/product/**`（preserve-only / 上書きされない）に置きます。
- **命名:** テスト対象ファイル名に `.test.` または `.spec.` を付与する（例: `user_service.ts` -> `user_service.test.ts`）。

## 3. 記述スタイル: AAAパターン
すべてのテストケースは **Arrange (準備) -> Act (実行) -> Assert (検証)** の3ステップで明確に区切って記述してください。

## 4. テンプレート (`example.test.ts`)

```typescript
import { UserService } from '../src/services/UserService';

describe('UserService', () => {
  // Arrange: テスト共通の準備
  let service: UserService;

  beforeEach(() => {
    service = new UserService();
  });

  describe('createUser()', () => {
    it('should create a new user successfully when data is valid', async () => {
      // Arrange
      const input = { name: 'Test User', email: 'test@example.com' };

      // Act
      const result = await service.createUser(input);

      // Assert
      expect(result.id).toBeDefined();
      expect(result.name).toBe(input.name);
    });

    it('should throw error when email is duplicated', async () => {
      // Arrange
      const input = { name: 'Duplicate User', email: 'existing@example.com' };
      // (Mock setup for existing user would go here)

      // Act & Assert
      await expect(service.createUser(input)).rejects.toThrow('Email already exists');
    });
  });
});
```

## 5. アーカイブ基準
- 機能廃止やリファクタリングにより**実行されなくなったテストコード**は、`.agent/archive/test/` へ移動させてください。
