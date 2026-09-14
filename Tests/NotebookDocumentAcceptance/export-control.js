// Run after the real iPad edit test with its documentID and optional marker.
// A later run with jobID observes the separate long-running export job.
if (args?.jobID) {
  await emit(await nb.exportStatus({ jobID: args.jobID }));
} else {
  if (!args?.documentID) throw new Error('Use the ID returned by create-control.js');
  const addressed = (await nb.document({ id: args.documentID, blockID: 'part-0' })).values[0];
  if (args.marker && !addressed?.block?.source?.includes(args.marker)) {
    throw new Error('The public Mac read does not yet contain the actual iPad edit');
  }
  const job = await nb.export('canonical-control-export', { documentID: args.documentID });
  await emit({ ...job, uiEditObserved: args.marker ? true : null });
}
