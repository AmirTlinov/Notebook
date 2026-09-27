// Run after the physical source/state scenario. A jobID reads the durable job.
if (args?.jobID) {
  await emit(await nb.exportStatus({jobID:args.jobID}));
} else {
  if (!args?.documentID) throw Error('Use the documentID returned by create-control.js');
  const fileID = args.fileID ?? 'introduction';
  const addressed = await nb.document({id:args.documentID,fileID});
  if (!addressed.data) throw Error('The selected source file is missing');
  if (args.marker && !addressed.data.file.source.includes(args.marker)) {
    throw Error('The public Mac source does not contain the actual iPad edit');
  }
  const format = args.format ?? 'pdf';
  if (!['pdf','package'].includes(format)) throw Error('Choose pdf or package (.notex)');
  const program = await nb.read({kind:'documentProgram',id:args.documentID,
    instanceID:args.instanceID??'oscillator',programPath:'programs/oscillator'});
  const job = await nb.export('latex-control-export', {documentID:args.documentID,format});
  await emit({...job,fileID,uiEditObserved:args.marker?true:null,observedSavedState:program.data.state,
    observedProgramSourceBasis:program.data.sourceBasis});
}
