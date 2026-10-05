// Node's test runner owns discovery and outcomes. Preserve those events rather
// than inferring test execution from a human summary or a process exit code.
export default async function* notebookReporter(events) {
  for await (const event of events) {
    if (['test:enqueue', 'test:pass', 'test:fail', 'test:summary'].includes(event.type)) {
      yield JSON.stringify(event) + '\n';
    }
  }
}
