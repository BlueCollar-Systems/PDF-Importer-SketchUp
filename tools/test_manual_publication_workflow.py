from pathlib import Path
import ast, re, unittest
ROOT=Path(__file__).resolve().parents[1]
def block(text,name,kind='job'):
    if kind=='job': pattern=r'(?ms)^  '+re.escape(name)+r':\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)'
    else: pattern=r'(?ms)^      - name: '+re.escape(name)+r'\n(.*?)(?=^      - (?:name:|uses:)|\Z)'
    match=re.search(pattern,text)
    if not match: raise AssertionError('Missing block '+name)
    return match.group(1)
def guard(body):
    match=re.search(r'^\s+if: (.+)$',body,re.M)
    if not match: raise AssertionError('Missing publication guard')
    value=match.group(1).strip()
    return ast.literal_eval(value) if value.startswith('"') else value
def run_guard(expression,event,flag,key,ref='refs/heads/main'):
    values={'github.event_name':event,'github.ref':ref,'inputs.'+key:flag,
      'github.event.head_commit.message':'normal source change',
      'needs.source-only-build-windows.outputs.publication_ready':'true',
      'steps.preflight.outputs.release':'true','steps.mint.outputs.release_verified':'true'}
    expression=re.sub(r'\b(?:github|inputs|needs|steps)(?:\.[A-Za-z0-9_-]+)+',lambda m:repr(values.get(m.group(0),'')),expression)
    expression=expression.replace('&&',' and ').replace('||',' or ')
    expression=re.sub(r'!(?!=)',' not ',expression)
    expression=re.sub(r'\btrue\b','True',expression)
    expression=re.sub(r'\bfalse\b','False',expression).strip()
    tree=ast.parse(expression,mode='eval')
    allowed=(ast.Expression,ast.BoolOp,ast.And,ast.Or,ast.UnaryOp,ast.Not,ast.Compare,ast.Eq,ast.NotEq,ast.Constant,ast.Call,ast.Name,ast.Load)
    for node in ast.walk(tree):
        if not isinstance(node,allowed):raise AssertionError('Unsupported condition')
        if isinstance(node,ast.Name) and node.id not in ('startsWith','contains'):raise AssertionError('Unknown function')
        if isinstance(node,ast.Call) and not isinstance(node.func,ast.Name):raise AssertionError('Unsafe call')
    return bool(eval(compile(tree,'<guard>','eval'),{'__builtins__':{},'startsWith':lambda v,p:str(v).startswith(p),'contains':lambda v,p:p in str(v)}))
class ManualPublicationWorkflowTest(unittest.TestCase):
    def manual_gate(self,expression,key):
        for event in ['push','pull_request','schedule','repository_dispatch','release']:
            for flag in [False,True,None,'false']:
                with self.subTest(event=event,flag=flag):self.assertFalse(run_guard(expression,event,flag,key))
        for flag in [False,None,'false']:
            self.assertFalse(run_guard(expression,'workflow_dispatch',flag,key))
        self.assertTrue(run_guard(expression,'workflow_dispatch',True,key))
    def boolean_false(self,text,key):
        header=text.split('\njobs:',1)[0]
        match=re.search(r'(?ms)^      '+re.escape(key)+r':\n(.*?)(?=^      [A-Za-z0-9_-]+:|\n\S|\Z)',header)
        self.assertIsNotNone(match)
        self.assertRegex(match.group(1),r'(?m)^        type: boolean$')
        self.assertRegex(match.group(1),r'(?m)^        default: false$')
    def test_importer_publication_is_manual(self):
        text=(ROOT/'.github/workflows/auto-release.yml').read_text(encoding='utf-8')
        self.boolean_false(text,'publish_release')
        self.manual_gate(guard(block(text,'release')),'publish_release')
        self.assertIn('  push:',text)
        self.assertNotIn('inputs.publish_release',block(text,'source-only-build-windows'))
    def test_shape_push_builds_without_publishing(self):
        text=(ROOT/'.github/workflows/steel-shapes-release.yml').read_text(encoding='utf-8')
        self.boolean_false(text,'publish_release')
        self.manual_gate(guard(block(text,'Publish exact non-product-latest release','step')),'publish_release')
        self.assertIn('  push:',text)
        self.assertIn('Upload validated shape pack for inspection',text)
        self.assertIn('ref: ${{ inputs.tag || github.ref }}',text)
        self.assertIn('--target "$(git rev-parse HEAD)"',text)
    def test_push_pr_validation_remains(self):
        text=(ROOT/'.github/workflows/su-pdfimporter-ci.yml').read_text(encoding='utf-8')
        self.assertIn('push:',text);self.assertIn('pull_request:',text)

if __name__=='__main__':unittest.main()
