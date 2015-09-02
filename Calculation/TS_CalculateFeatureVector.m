function [featureVector,calcTimes,calcQuality] = TS_CalculateFeatureVector(tsStruct,doParallel,Operations,MasterOperations,beVocal)
% TS_CalculateFeatureVector	Compute a feature vector from an input time series

% ------------------------------------------------------------------------------
% Copyright (C) 2015, Ben D. Fulcher <ben.d.fulcher@gmail.com>,
% <http://www.benfulcher.com>
%
% If you use this code for your research, please cite:
% B. D. Fulcher, M. A. Little, N. S. Jones, "Highly comparative time-series
% analysis: the empirical structure of time series and their methods",
% J. Roy. Soc. Interface 10(83) 20130048 (2010). DOI: 10.1098/rsif.2013.0048
%
% This work is licensed under the Creative Commons
% Attribution-NonCommercial-ShareAlike 4.0 International License. To view a copy of
% this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send
% a letter to Creative Commons, 444 Castro Street, Suite 900, Mountain View,
% California, 94041, USA.
% ------------------------------------------------------------------------------

%-------------------------------------------------------------------------------
% Check Inputs
%-------------------------------------------------------------------------------
if isnumeric(tsStruct)
	% Provided data only without metadata:
	tsData = tsStruct;
	tsStruct = struct('Name','Input Timeseries', ...
						'Data',tsData, ...
						'ID',1, ...
						'Length',length(tsData));
end
if nargin < 2
	doParallel = 0;
end
if nargin < 3 || isempty(Operations) || ischar(Operations)
	% Use a default library:
	if nargin >=3 && ischar(Operations)
		theINPfile = Operations;
	else
		theINPfile = 'INP_ops.txt';
	end
	Operations = SQL_add('ops', theINPfile, 0, 0)';
end
if nargin < 4 || isempty(MasterOperations)
	% Use the default library:
	MasterOperations = SQL_add('mops', 'INP_mops.txt', 0, 0)';
end

% Need to link operations to masters if not already supplied:
if nargin < 4
	[Operations, MasterOperations] = TS_LinkOperationsWithMasters(Operations,MasterOperations);
end

% Whether to give information out to screen
if nargin < 5
	beVocal = 1;
end

% ------------------------------------------------------------------------------
%% Open parallel processing worker pool
% ------------------------------------------------------------------------------
if doParallel
    % Check that a parallel worker pool is open (if not initiate it):
	doParallel = TS_InitiateParallel(0);
end
if doParallel
	fprintf(1,['Computation will be performed across multiple cores' ...
			' using Matlab''s Parallel Computing Toolbox.\n'])
else % use single-threaded for loops
	fprintf(1,'Computations will be performed serially without parallelization.\n')
end

% --------------------------------------------------------------------------
%% Basic checking on the data
% --------------------------------------------------------------------------
% (Univariate and [N x 1])
x = tsStruct.Data;
if size(x,2) ~= 1
	if size(x,1) == 1
		fprintf(1,['***** The time series %s is a row vector. Not sure how it snuck through the cracks, but I ' ...
								'need a column vector...\n'],tsStruct.Name);
		fprintf(1,'I''ll transpose it for you for now....\n');
		x = x';
	else
		fprintf(1,'******************************************************************************************\n')
		error('ERROR WITH ''%s'' -- is it multivariate or something weird? Skipping!\n',tsStruct.Name);
	end
end


%-------------------------------------------------------------------------------
numCalc = length(Operations); % Number of features to calculate
featureVector = zeros(numCalc,1); % Output of each operation
calcQuality = zeros(numCalc,1); % Quality of output from each operation
calcTimes = ones(numCalc,1)*NaN; % Calculation time for each operation

% --------------------------------------------------------------------------
%% Pre-Processing
% --------------------------------------------------------------------------
% y is a z-scored transformation of the time series
% z-score without using a Statistics Toolbox license (i.e., the 'zscore' function):
y = BF_zscore(x);

% So we now have the raw time series x and the z-scored time series y.
% Operations take these as inputs.

% --------------------------------------------------------------------------
%% Evaluate all master operation functions (maybe in parallel)
% --------------------------------------------------------------------------
% Because of parallelization, we have to evaluate all the master functions *first*
% Check through the metrics to determine which master functions are relevant for this run

% Put the output from each Master operation in an element of MasterOutput
MasterOutput = cell(length(MasterOperations),1); % Ouput structures
MasterCalcTime = zeros(length(MasterOperations),1); % Calculation times for each master operation

Master_IDs_calc = unique([Operations.MasterID]); % Master_IDs that need to be calculated
Master_ind_calc = arrayfun(@(x)find([MasterOperations.ID]==x,1),Master_IDs_calc); % Indicies of MasterOperations that need to be calculated
numMopsToCalc = length(Master_IDs_calc); % Number of master operations to calculate

% Index sliced variables to minimize the communication overhead in the parallel processing
par_MasterOpCodeCalc = {MasterOperations(Master_ind_calc).Code}; % Cell array of strings of Code to evaluate
par_mop_ids = [MasterOperations(Master_ind_calc).ID]; % mop_id for each master operation

fprintf(1,'Evaluating %u master operations...\n',length(Master_IDs_calc));

% Store in temporary variables for parfor loop then map back later
MasterOutput_tmp = cell(numMopsToCalc,1);
MasterCalcTime_tmp = zeros(numMopsToCalc,1);

% ----
% Evaluate all the master operations
% ----
TimeSeries_i_ID = tsStruct.ID; % Make a PARFOR-friendly version of the ID
masterTimer = tic;
if doParallel
	parfor jj = 1:numMopsToCalc % PARFOR Loop
		[MasterOutput_tmp{jj}, MasterCalcTime_tmp(jj)] = ...
					TS_compute_masterloop(x,y,par_MasterOpCodeCalc{jj}, ...
								par_mop_ids(jj),numMopsToCalc,beVocal,TimeSeries_i_ID,jj);
	end
else
	for jj = 1:numMopsToCalc % Normal FOR Loop
		[MasterOutput_tmp{jj}, MasterCalcTime_tmp(jj)] = ...
					TS_compute_masterloop(x,y,par_MasterOpCodeCalc{jj}, ...
								par_mop_ids(jj),numMopsToCalc,beVocal,TimeSeries_i_ID,jj);
	end
end

% Map from temporary versions to the full versions:
MasterOutput(Master_ind_calc) = MasterOutput_tmp;
MasterCalcTime(Master_ind_calc) = MasterCalcTime_tmp;

fprintf(1,'%u master operations evaluated in %s ///\n\n',...
					numMopsToCalc,BF_thetime(toc(masterTimer)));
clear masterTimer

% --------------------------------------------------------------------------
%% Assign all the results to the corresponding operations
% --------------------------------------------------------------------------
% Set sliced version of matching indicies across the range toCalc
% Indices of MasterOperations corresponding to each Operation (i.e., each index of toCalc)
par_OperationMasterInd = arrayfun(@(x)find([MasterOperations.ID]==x,1),[Operations.MasterID]);
par_MasterOperationsLabel = {MasterOperations.Label}; % Master labels
par_OperationCodeString = {Operations.CodeString}; % Code string for each operation to calculate (i.e., in toCalc)

if doParallel
	parfor jj = 1:numCalc
		[featureVector(jj), calcQuality(jj), calcTimes(jj)] = TS_compute_oploop(MasterOutput{par_OperationMasterInd(jj)}, ...
									   MasterCalcTime(par_OperationMasterInd(jj)), ...
									   par_MasterOperationsLabel{par_OperationMasterInd(jj)}, ...
									   par_OperationCodeString{jj});
	end
else
	for jj = 1:numCalc
		try
			[featureVector(jj), calcQuality(jj), calcTimes(jj)] = TS_compute_oploop(MasterOutput{par_OperationMasterInd(jj)}, ...
											   MasterCalcTime(par_OperationMasterInd(jj)), ...
											   par_MasterOperationsLabel{par_OperationMasterInd(jj)}, ...
											   par_OperationCodeString{jj});
		catch
			fprintf(1,'---Error with %s\n',par_OperationCodeString{jj});
			keyboard
			if (MasterOperations(par_OperationMasterInd(jj)).ID == 0)
				error(['The operations database is corrupt: there is no link ' ...
						'from ''%s'' to a master code'], par_OperationCodeString{jj});
			else
				fprintf(1,'Error retrieving element %s from %s.\n', ...
					par_OperationCodeString{jj}, par_MasterOperationsLabel{par_OperationMasterInd(jj)})
			end
		end
	end
end

% --------------------------------------------------------------------------
%% Code special values:
% --------------------------------------------------------------------------
% (*) Errorless calculation: q = 0, Output = <real number>
% (*) Fatal error: q = 1, Output = 0; (this is done already in the code above)

% (*) Output = NaN: q = 2, Output = 0
RR = isnan(featureVector); % NaN
if any(RR)
	calcQuality(RR) = 2; featureVector(RR) = 0;
end

% (*) Output = Inf: q = 3, Output = 0
RR = (isinf(featureVector) & featureVector > 0); % Inf
if any(RR)
	calcQuality(RR) = 3; featureVector(RR) = 0;
end

% (*) Output = -Inf: q = 4, Output = 0
RR = (isinf(featureVector) & featureVector < 0);
if any(RR)
	calcQuality(RR) = 4; featureVector(RR) = 0;
end

% (*) Output is a complex number: q = 5, Output = 0
RR = (imag(featureVector)~=0);
if any(RR)
	calcQuality(RR) = 5; featureVector(RR) = 0;
end

end
