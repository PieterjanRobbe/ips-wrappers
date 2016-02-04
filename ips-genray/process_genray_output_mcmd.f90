      program process_genray_output

!- -------------------------------------------------------------------
! Batchelor 9/29/2010
! This version, process_genray_output_mcmd.f90, differs from the previous
! version, process_genray_output.f90,  only in that it calls PS_WRITE_UPDATE_FILE
! instead of ps_store_plasma_state.  This enables it to be used in the concurrent
! IPS framework without clobbering updates to the plasma state made by other
! components.	
!
! Note: To merge plasma states the IPS framework expects the component to
! produce a partial state file with the component-specific name:
! <component>_<curr_state_filemname>.  This code works for EC, LH, and IC, i.e.
! it can implement several different components.  Therefore we write a
! partial state file with generic name 'RF_GENRAY_PARTIAL_STATE' and delegete
! to the python component script the copying of this to the proper 
! component-specific update file name.

!- -------------------------------------------------------------------
! Processing genray output.
! BobH, 06/03/08
!
! This program reads rf current and power deposition profiles
! from a netcdf file, genray.nc, generated by the genray ray 
! tracing code, and transfers this data to the plasma state (PS) module.
! 
!     process_genray_output takes up to 2 optional command line
!     arguments:   1st: rfmode ('EC','LH','IC' are possible inputs)
!                       default='EC'
!                  2nd: isource_string=RF Source number
!                       default=1
!     The rfmode and source number is input, to point to the desired
!     location in the PS.
!
! To obtain powers and currents summed over RF sources, it is assumed
! that at each required time step, and for a given rfmode, this code 
! is called first with isource_string='1', and then subsequently with 
! a larger number
! (if not all sources for the particular mode are handled by 
! isource_string='1' plus data for the number of sources in the genray.nc
! file). More on this....
!
! From prepare_genray_input.f90:
!     isource_string keeps count of the source numbers for each
!     rfmode.   The aim with the associated process_genray_output.f90
!     code is that if isource_string is greater than 1, 
!     then powers and currents are accumulated in the PS,
!     as required, for given rfmode.
!     If the wave frequencies are equal for all sources for
!     given rfmode, usually all sources can be entered through
!     one genraynml file, and the power deposition and current
!     drive for all sources will be attributed in process_genray_output
!     to the isource_string source.  [Genray can only do one
!     frequency at a time.  Also, if treating several sources,
!     i.e, EC-like cones or LH/FW-like grills, for a given frequency,
!     it accumulates the power deposition and current drive
!     without recording which source is responsible.]
!     For sources with given rfmode but
!     different frequencies, isource_string is expected to have
!     the PS value of the first source in the set for that
!     frequency. (Usually it will be most convenient if sources
!     in the plasma state are grouped by frequency.)  For PS
!     storage which depends on isource_string, the genray data
!     for all sources specified in a given genraynml will be
!     stored in the locations associated with the given isource_string,
!     as if the data were for a single source.
!
!     If separate entries of power deposition and current drive
!     are desired in the PS for each source, then there needs to be
!     separate genraynml for each source, and separate calls for each
!     to prepare_genray_input, xgenray, process_genray_output.
!     For each rfmode, the isource_string values would be advanced
!     by 1 for each source.
!

!--------------------------------------------------------------------
!
!.......................................................................
!
!     Compile and load line:
!     lf95 --fix -o process_genray_output process_genray_ouput.f90 
!     or
!
!viz.pppl.gov compile:
! ifort -fixed -80 -c -O -w -mp -fpe0 -heap-arrays 20 -I$NTCCHOME/mod -I$NETCDFHOME/include -o process_genray_output.o  process_genray_output.f90
!viz.pppl.gov load: (with module ntcc/intel.10.1_mkl.10)
! ifort -fpe0 -o process_genray_output    process_genray_output.o  -L$NTCCHOME/lib -lplasma_state -lps_xplasma2 -lplasma_state_kernel -lxplasma2 -lgeqdsk_mds -lmdstransp -lvaxonly -lnscrunch -lfluxav -lr8bloat -lpspline -lezcdf -llsode -llsode_linpack -lcomput -lportlib -L$MDSPLUS_DIR/lib -L$GLOBUS_LOCATION/lib -lMdsLib -lglobus_xio_gcc64  -L$MKLHOME/lib/64 -lmkl_lapack -lmkl_ipf -lmkl_sequential -lmkl_core -lguide -lpthread -L$NETCDFHOME/lib -lnetcdf

!viz.pppl.gov load: (with module ntcc/intel.10.0_mkl.9)
! ifort -fpe0 -o process_genray_output    process_genray_output.o  -L$NTCCHOME/lib -lplasma_state -lps_xplasma2 -lplasma_state_kernel -lxplasma2 -lgeqdsk_mds -lmdstransp -lvaxonly -lnscrunch -lfluxav -lr8bloat -lpspline -lezcdf -llsode -llsode_linpack -lcomput -lportlib -L$MDSPLUS_DIR/lib -L$GLOBUS_LOCATION/lib -lMdsLib -lglobus_xio_gcc64  -L$MKLHOME/lib/64 -lmkl_lapack -lmkl_ipf -lpthread  -lguide -lpthread -L$NETCDFHOME/lib -lnetcdf

!
! Interpolation methods for profiles are part of the state specification
! "swim_state_spec.dat" and are handled by generated code.
!-----------------------------------

! define state object and interface...

      USE plasma_state_mod
!--------------------------------------------------------------------------

      USE swim_global_data_mod, only :
     1 rspec, ispec,     ! kind specification for real (64-bit)
                         ! and integer (32-bit).
     1 swim_error,       ! error routine

     1 swim_filename_length   ! length of filename string
    

    
!--------------------------------------------------------------------------
!
!   Data declarations
!
!---------------------------------------------------------------------
 
!     IMPLICIT NONE
      implicit integer (i-n), real*8 (a-h,o-z)

! --- GENRAY related items:
!     Obtaining data from genral genray netcdf file,
!     not genray_profs_out.nc  [Alternatively (a code mod), if too much 
!     data is generated in the genray.nc file, BH could create a new 
!     genray_profs_out2.nc file containing
!     bin-centered powers and currents rather than bin-boundary as 
!     in genray_profs_out.nc. ]

!     rho_bin= normalized radial bin-boundary grid, sqrt(tor flux)

      real *8,dimension(:),allocatable :: rho_bin  !size nrho
      real *8,dimension(:),allocatable :: binarea,binvol  !size nrho-1
      real *8,dimension(:),allocatable :: powden_e,powden_i,
     1     s_cur_den_toroidal                      !size nrhom=nrho-1
      real *8,dimension(:),allocatable :: powtot_s !size nbulkm=nbulk-1
      real *8,dimension(:,:),allocatable :: powden_s  
                                                  !size nbulkm,nrhom
      real *8,dimension(:),allocatable :: charge_nc,dmass_nc  !size nbulk
      real *8  power_inj_total,power_total,powtot_e,powtot_i,
     +         toroidal_cur_total

! --- end GENRAY related items

      character*8 rfmode,isource_string
      integer iargs,isource

      integer :: cclist(ps_ccount)  ! state partial copy controls

  !------------------------------------
  !  local
      INTEGER :: ierr
      INTEGER :: iout = 6



c     Storage for netcdf file elements and retrieval

c --- include file for netCDF declarations 
c --- (obtained from NetCDF distribution)
      include 'netcdf.inc'

c --- some stuff for netCDF file ---
      character(swim_filename_length) netcdf_file
      integer ncid,vid,istatus
      character name*128
      integer start(2),count(2),char256dim
      integer nbulk,nbulkm,nrho,nrhom
      integer nbulk_id,nbulkm_id,nrho_id,nrhom_id
c
      data start/1,1/


c  -----------------------------------------------------------------------
c     Get/setup command line arguments
c  -----------------------------------------------------------------------

      rfmode='EC'
      isource_string='1'
c F2003 syntax      iargs=command_argument_count()
c Here, use portlib routines (also used by PS module)

      call get_arg_count(iargs)

      if (iargs.ne.2) then
         write(*,*)'process_genray_output usage: '
         write(*,*)'Up to two command line arguments, '
         write(*,*)'rfmode isource_sting [refer to code]'
      endif

c F2003-syntax if(iargs.ge.1)call get_command_argument(1,rfmode)
c F2003-syntax if(iargs.ge.2)call get_command_argument(2,isource_string)
c Here, use portlib routines (also used by PS module)
      if (iargs.ge.1)   call get_arg(1,rfmode)
      if (iargs.ge.2)   call get_arg(2,isource_string)

      rfmode=trim(rfmode)
      isource_string=trim(isource_string)

      write(iout,*)'process_genray_output command line arguments: ',
     +  rfmode,isource_string


      read(isource_string, '(i4)') isource


c  -----------------------------------------------------------------------
c     Retrive the plasma state at the present PS,
c     plus setup the storage for the PS variables
c  -----------------------------------------------------------------------
  
   
      write(iout,*)
      write(iout,*) 'process_genray_output: -- restoring plasma state'
     1              //' from file -- '

      CALL ps_get_plasma_state(ierr)

      if(ierr.ne.0) then
         write(iout,*) 'process genray: ps_get_plasma_state: ierr=',ierr
         stop
      endif

c

c  -----------------------------------------------------------------------
c     Read relevant netCDF data produced by ray-tracing code,
c     and put it into the Plasma State
c  -----------------------------------------------------------------------
c

c     obtain netcdf_file id number from the netcdf file

c     [Here, using genray.nc file.   Could modify genray_profs_out.nc
c     from present slightly incompatible bin boundary data (designed 
c     for ONETWO) to incorporate abridged bin centered power abs
c     and current data as in genray.nc.   The shorter file could
c     reduce run storage.]
c     
      netcdf_file='genray.nc'
      ncid = ncopn(netcdf_file,NCNOWRIT,istatus)
      write(*,*)'after ncopn ncid=',ncid,'istatus',istatus
c.......................................................................
c     read in dimension IDs:
c     nrho is number of radial mesh bin boundaries, and is 
c       genray namelist input variable NR. 
c     nrhom (=nrho-1) number of bins,
c     nbulk is number of species accounted for, including electrons.

      nrho_id = ncdid(ncid,'nrho',istatus)
      write(*,*)'after ncdid nrho_id=',nrho_id,'istatus',istatus
      nrhom_id = ncdid(ncid,'nrhom',istatus)
      write(*,*)'after ncdid nrhom_id=',nrhom_id,'istatus',istatus
      nbulk_id = ncdid(ncid,'nbulk',istatus)
      write(*,*)'after ncdid nbulk_id=',nbulk_id,'istatus',istatus

c --- inquire about dimension sizes:#grid size,species number---
      call ncdinq(ncid,nrho_id,name,nrho,istatus)
      call ncdinq(ncid,nrhom_id,name,nrhom,istatus)
      call ncdinq(ncid,nbulk_id,name,nbulk,istatus)


c     If nbulk=1, then there is only an electron species (e.g., in
c     an EC case). Zeff is also passed, for current drive calculation.
c     With ions (for LH and IC cases), nbulk will be .ge.2, and 
c     nbulkm=nbulk-1 .ge.1.
      count(1)=nrhom
      count(2)=0
      if (nbulk.gt.1) then
         nbulkm_id = ncdid(ncid,'nbulkm',istatus)
         write(*,*)'after ncdid nbulkm_id=',nbulkm_id,'istatus',istatus
         call ncdinq(ncid,nbulkm_id,name,nbulkm,istatus)
         count(2)=nbulkm
      endif

c     Read radial coord type, to check it is sqrt(tor flux)
      vid = ncvid(ncid,'indexrho',istatus)   !radial coord type
      call ncvgt(ncid,vid,1,1,indexrho,istatus)

      write(*,*)'call_genray:nbulk,nrho,indexrho ',
     .     nbulk,nrho,indexrho

      if (indexrho.ne.2) then
         write(*,*)'call_genray: problem with genray radial coord type'
         STOP
      endif

      !allocate storage and initialize to zero:
c  -----------------------------------------------------------------------

      if(.not. allocated(rho_bin))then
         allocate (rho_bin(nrho),STAT = istat)
         if(istat .ne. 0)
     +     call allocate_error("rho_bin, process_genray_output",0,istat)
      endif
      rho_bin=(/(0.0_rspec,i=1,nrho)/)

      if(.not. allocated(binarea))then
         allocate (binarea(nrhom),STAT = istat)
         if(istat .ne. 0)
     +     call allocate_error("binarea, process_genray_output",0,istat)
      endif
      binarea=(/(0.0_rspec,i=1,nrhom)/)

      if(.not. allocated(binvol))then
         allocate (binvol(nrhom),STAT = istat)
         if(istat .ne. 0)
     .     call allocate_error("binvol, process_genray_output",0,istat)
      endif
      binvol=(/(0.0_rspec,i=1,nrhom)/)

      if(.not. allocated(powden_e))then
         allocate (powden_e(nrhom),STAT = istat)
        if(istat .ne. 0)
     .    call allocate_error("powden_e, process_genray_output",0,istat)
      endif
      powden_e=(/(0.0_rspec,i=1,nrhom)/)

      if(.not. allocated(s_cur_den_toroidal))then
         allocate (s_cur_den_toroidal(nrhom),STAT = istat)
        if(istat .ne. 0)
     .    call allocate_error("s_cur_den_toroidal,"//
     .                        " process_genray_output",0,istat)
      endif
      s_cur_den_toroidal=(/(0.0_rspec,i=1,nrhom)/)

      if(.not. allocated(powden_i))then
         allocate (powden_i(nrhom),STAT = istat)
         if(istat .ne. 0)
     .     call allocate_error("powden_i,sub call_genray",0,istat)
      endif
      powden_i=(/(0.0_rspec,i=1,nrhom)/)
      
      if (nbulk.gt.1) then
      if(.not. allocated(powden_s))then
         allocate (powden_s(nrhom,nbulkm),STAT = istat)
         if(istat .ne. 0)
     .     call allocate_error("powden_s,process_genray_output",0,istat)
      endif
      do j=1,nbulk-1
         do i=1,nrhom
            powden_s(i,j)=0.0_rspec
         enddo			
      enddo			
      
      if(.not. allocated(powtot_s))then
         allocate (powtot_s((nbulk-1)),STAT = istat)
         if(istat .ne. 0)
     .     call allocate_error("powtot_s,process_genray_output",0,istat)
      endif
      powtot_s=(/(0.0_rspec,i=1,nbulk-1)/)
      endif

      power_inj_total=0.0_rspec
      power_total=0.0_rspec
      powtot_e=0.0_rspec
      powtot_i=0.0_rspec
      toroidal_cur_total=0.0_rspec
      


c     Read data from netcdf file
c  ----------------------------------------------------------------------

! Normalized radial grid at bin boundaries rho ~sqrt(tor flux)
      vid = ncvid(ncid,'rho_bin',istatus)  
      call ncvgt(ncid,vid,1,nrho,rho_bin,istatus)

! Poloidal cross-sectional area of bins (cm**2)
      vid = ncvid(ncid,'binarea',istatus)  
      call ncvgt(ncid,vid,1,nrhom,binarea,istatus)

! Volume of bins (cm**3)
      vid = ncvid(ncid,'binvol',istatus)  
      call ncvgt(ncid,vid,1,nrhom,binvol,istatus)

! FSA power density to electrons vs radius (ergs/(sec*cm**3))
      vid = ncvid(ncid,'powden_e',istatus)   
      call ncvgt(ncid,vid,1,nrhom,powden_e,istatus)

! Integrated power to electrons (Watts)
      vid = ncvid(ncid,'powtot_e',istatus)
      call ncvgt(ncid,vid,1,1,powtot_e,istatus)

         
! FSA power density to all ions vs radius (ergs/(sec*cm**3))
         vid = ncvid(ncid,'powden_i',istatus)   
         call ncvgt(ncid,vid,1,nrhom,powden_i,istatus)

! Integrated power to all ions (ergs/sec)
         vid = ncvid(ncid,'powtot_i',istatus)
         call ncvgt(ncid,vid,1,1,powtot_i,istatus)

! FSA power density to each ion vs radii pgri(1:nbulkm,1:nrhom)
! (ergs/(sec*cm**3))  This power breakdown is presently (Feb'09)
! available for multi-ion simulation setups with genray iabsorp=3.

! Read iabsorp, flag for type of absorption calculation
      vid = ncvid(ncid,'iabsorp',istatus)
      call ncvgt(ncid,vid,1,1,iabsorp,istatus)
	
      if (nbulk.gt.1 .and. iabsorp.eq.3) then

         vid = ncvid(ncid,'powden_s',istatus)
         call ncvgt(ncid,vid,start,count,powden_s,istatus)
         
! Integrated power to each ion species (ergs/sec)
         vid = ncvid(ncid,'powtot_s',istatus)   
         call ncvgt(ncid,vid,1,nbulk-1,powtot_s,istatus)

      endif

! Total rf injected power in this mode (ergs/sec)
      vid = ncvid(ncid,'power_inj_total',istatus)
      call ncvgt(ncid,vid,1,1,power_inj_total,istatus)

! Rf toroidal current density vs radius (A/cm**2)
      vid = ncvid(ncid,'s_cur_den_toroidal',istatus)
      call ncvgt(ncid,vid,1,nrhom,s_cur_den_toroidal,istatus)

! Total rf driven current (Amps)
      vid = ncvid(ncid,'toroidal_cur_total',istatus)
      call ncvgt(ncid,vid,1,1,toroidal_cur_total,istatus)


      if (nbulk .gt. 1) then
      write(*,*)' '
      write(*,*)'******************************************************'
      write(*,*)'call_genray:  For the time being, power to a hot'
      write(*,*)'call_genray:  Maxwellian ion distn representing beam'
      write(*,*)'call_genray:  ions can be calculated in genray,'
      write(*,*)'call_genray:  and affects accounting for power.'
      write(*,*)'call_genray:  One possibility is to divvy it up'
      write(*,*)'call_genray:  as additional source power to  e and i'
      write(*,*)'call_genray:  based on Coulomb rates.'
      write(*,*)'******************************************************'
      write(*,*)' '
      endif


!.......................................................................
!     Set some Plasma State variables
!.......................................................................



      if (rfmode.eq.'EC') then

c$$$   Following moved to ipsmode='init' functionality in prepare_genray_input
c$$$!  Necessary PS dimensions (user has to set his component dims):
c$$$         if(ps%nrho_ecrf.eq.nrho) then
c$$$            continue   ! dimension OK already
c$$$         else if(ps%nrho_ecrf.eq.0) then
c$$$            ps%nrho_ecrf=nrho
c$$$            call ps_alloc_plasma_state(ierr) !set these PS dims in PS
c$$$         else if(ps%nrho_ecrf.ne.nrho) then
c$$$            write(*,*) 
c$$$     +           ' * process_genray_output: reset EC profile size'
c$$$            write(*,*) ' * from ',ps%nrho_ecrf,' to ',nrho
c$$$
c$$$            ! copy all EXCEPT EC component profiles
c$$$            cclist = ps_cc_all
c$$$            cclist(ps_cnum_EC)=0
c$$$
c$$$            call ps_copy_plasma_state(ps, aux, ierr, cclist = cclist)
c$$$            if(ierr.eq.0) then
c$$$               ! OK, copy back to ps
c$$$               call ps_copy_plasma_state(aux, ps, ierr)
c$$$
c$$$               if(ierr.eq.0) then
c$$$                                ! set desired dimension
c$$$                  ps%nrho_ecrf=nrho
c$$$                  call ps_alloc_plasma_state(ierr) !set these PS dims in PS
c$$$               endif
c$$$            endif
c$$$         endif
c$$$
c$$$         if (ierr.ne.0) then
c$$$            write(*,*)'process_genray_output:  EC'//
c$$$     +           ' ps_alloc_plasma_state: ierr=',ierr
c$$$            stop
c$$$         endif

c  For safety, check ps%rho_ecrf is equal to rho_bin [from genray]
	 do l=2,nrho
	    if ((ps%rho_ecrf(l)-rho_bin(l))/rho_bin(l) .gt.1.e-10) then
	        stop 'process_genray_output: rho problem'
	    endif
	 enddo
c     Zero out ps%peech and ps%curech only for first source, and
c     accumulate radial profiles from 1st and any subsequent sources.
         if (isource.eq.1) then
            ps%peech=0.0_rspec
            ps%curech=0.0_rspec
         endif

         do l=1,nrhom
            ps%peech(l)=ps%peech(l)+
     +           powden_e(l)*binvol(l)*1.e-7_rspec !Watts
            ps%curech(l)=ps%curech(l)+
     +           s_cur_den_toroidal(l)*binarea(l) !Amps
         enddo
c        Check and printout integrated powers and currents from genray
c        and using PS subroutine.
c        Add collisional power absorption to ions?  

      elseif(rfmode.eq.'LH') then
c$$$   Following moved to ipsmode='init' functionality in prepare_genray_input
c$$$         ps%nrho_lhrf=nrho
c$$$         call ps_alloc_plasma_state(ierr) !set these PS dims in PS
c$$$         if (ierr.ne.0) then
c$$$            write(*,*)'process_genray_output:  LH'//
c$$$     +           ' ps_alloc_plasma_state: ierr=',ierr
c$$$            stop
c$$$         endif

c  For safety, check ps%rho_lhrf is equal to rho_bin [from genray]
	 do l=2,nrho
	    if ((ps%rho_lhrf(l)-rho_bin(l))/rho_bin(l) .gt.1.e-10) then
	        stop 'process_genray_output: rho problem'
	    endif
	 enddo

c        Zero out ps%pelh, ps%pilh and ps%curlh only for first source.
c        Subsequent sources to be summed over.
         if (isource.eq.1) then
            ps%pelh=0.0_rspec
            ps%pilh=0.0_rspec
            ps%curlh(l)=0.0_rspec
         endif

         do l=1,nrhom
            ps%pelh(l)=ps%pelh(l)+powden_e(l)*binvol(l)*1.e-7_rspec  !Watts
            ps%pilh(l)=ps%pilh(l)+powden_i(l)*binvol(l)*1.e-7_rspec  !Watts
            ps%curlh(l)=ps%curlh(l)+s_cur_den_toroidal(l)*binarea(l)  !Amps
         enddo

      elseif(rfmode.eq.'IC') then
c$$$   Following moved to ipsmode='init' functionality in prepare_genray_input
c$$$         ps%nrho_icrf=nrho
c$$$         call ps_alloc_plasma_state(ierr) !set these PS dims in PS
c$$$         if (ierr.ne.0) then
c$$$            write(*,*)'process_genray_output:  IC'//
c$$$     +           ' ps_alloc_plasma_state: ierr=',ierr
c$$$            stop
c$$$         endif



      write(*,*)' '
      write(*,*)'******************************************************'
      write(*,*)'remode.eq.IC:  Need to adjust ion species list match'
      write(*,*)'remode.eq.IC:  up between genray and PS, as is done in'
      write(*,*)'remode.eq.IC:  prepare_genray_input, to assign power/'
      write(*,*)'remode.eq.IC:  current to the correct ions species.'
      write(*,*)'remode.eq.IC:  Stopping code, until this fix is in.'
      write(*,*)'remode.eq.IC:  BH, 20111109.'
      write(*,*)'******************************************************'
      write(*,*)' '
      STOP




c  For safety, check ps%rho_icrf is equal to rho_bin [from genray]
	 do l=2,nrho
	    if ((ps%rho_icrf(l)-rho_bin(l))/rho_bin(l) .gt.1.e-10) then
	        stop 'process_genray_output: rho problem'
	    endif
	 enddo

c        Zero out ps%picrf_totals, ps%picth, ps%curich=0.0_rspec 
c        only for first source. Sum over subsequent sources.
c        Species 0 is electrons.
         if (isource.eq.1) then
            ps%picrf_totals=0.0_rspec !picrf_totals(~nrho_icrf,0:nspec_alla)
            ps%picth=0.0_rspec  !picth(~nrho_icrf)
            ps%curich=0.0_rspec  !curich(~nrho_icrf)
         endif

         do l=1,nrhom
            ps%picrf_srcs(l,isource,0)=powden_e(l)*binvol(l)*1.e-7_rspec  !Watts
            ps%picrf_totals(l,0)=ps%picrf_totals(l,0)
     +              +powden_e(l)*binvol(l)*1.e-7_rspec !Watts
            do k=1,nbulkm       !No-op if nbulkm=0 (not expected for IC)
               ps%picrf_srcs(l,isource,k)=powden_s(l,k)*binvol(l)
     +              *1.e-7_rspec !Watts
               ps%picrf_totals(l,k)=ps%picrf_totals(l,k)
     +              +powden_s(l,k)*binvol(l)*1.e-7_rspec !Watts
            enddo
            ps%cdicrf(l,isource)=s_cur_den_toroidal(l)*binarea(l) 
                                 !cdicrf(~nrho_icrf,nicrf_src) Amps
            ps%curich(l)=ps%curich(l)+s_cur_den_toroidal(l)*binarea(l) !Amps
         enddo
            
      endif

	    

      write(iout,*)
     +     'process_genray_output: --storing genray data in current PS'

    !--------------------------------------------------------------------------    !
    ! Store the data in partial plasma_state file
    !--------------------------------------------------------------------------

	  CALL PS_WRITE_UPDATE_FILE('RF_GENRAY_PARTIAL_STATE', ierr)
	  WRITE (*,*) "Stored Partial RF Plasma State"    
c
      end   !end process_genray_output



c     
c     
      integer function length_char(string)
c     Returns length of string, ignoring trailing blanks,
c     using the fortran intrinsic len().
      character*(*) string
      do i=len(string),1,-1
         if(string(i:i) .ne. ' ') goto 20
      enddo
 20   length_char=i
      return
      end
c       
c
      subroutine check_err(iret)
      integer iret
      include 'netcdf.inc'
      if (iret .ne. NF_NOERR) then
         write(*,*)  'check_err:  netCDF error'
         stop
      endif
      return
      end
c

!
      subroutine allocate_error(var,myid,istat)
      character *(*) var
      integer istat,myid
      write(*,1)var,istat,myid
 1    format(2x,"Memory Allocation error encountered",/, 
     +     2x,"Unable to deallocate ",a,/, 
     +     2x,"status =",i5) 
      istat =0 !reset for next case
      return
      end      subroutine allocate_error
!

