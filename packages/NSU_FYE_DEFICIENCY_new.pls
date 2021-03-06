create or replace PROCEDURE        NSU_FYE_DEFICIENCY AS

/*************************************************
PROCEDURE nsu_fye_deficiency
     This process checks for test scores and courses in order to automatically resolve holds in the SOAHOLD Banner screen.
    
Northeastern State Univerisity
    unk         unk     in PROD
    31-May-19   sw      SR 9467201 from Julia Carlo: changes to test scores, types.
                        Also began documenting code internally
    
*************************************************/

    t_dat_file_def utl_file.file_type;
    t_line_def varchar2(200);
    t_stu_dir varchar2(20) := 'U13_STUDENT';
    lv_resolved_adm varchar2(1) :=null;
    lv_resolved_act varchar2(1) :=null;
    lv_resolved_cpt varchar2(1) :=null;
    lv_cpt_score numeric := 0;
    lv_new_cpt_score numeric := 0;
    lv_ang_score numeric := 0;
    lv_resolved_crse varchar2(1) :=null;
    lv_resolved varchar2(1) :=null;
    
    CURSOR c_def IS -- Get people with current academic holds, codes for Eng,Math,Reading,Sci- hold codes at STVHLDD
    SELECT
        spriden_id,
        spriden_first_name,
        spriden_last_name ,
        sprhold_pidm,
        sprhold_hldd_code ,
        sprhold.rowid this_row,
        to_char(sprhold_from_date,'DD-MON-YYYY') hold_start,
        to_char(sprhold_to_date,'DD-MON-YYYY') hold_end,
        
        -- resolve_code: English/Math/Reading/Science Deficiency Cleared code present in SORTEST, checked in is_resolved_ind()
        decode(sprhold_hldd_code, '13','ENGA',  '62','ENGA','14','MTHA','15','MTHA','63','MTHA','16','REDA','64','REDA','17','SCIA','18','SCIA',null) resolve_code,
        
        -- act_code: ACT sections, checked in is_resolved_test_score()
        decode(sprhold_hldd_code, '13','A01',   '62','A01', '14','A02', '15','A02', '63','A02', '16','A03', '64','A03', '17','A04','18','A04',null) act_code,
        
        -- sat_code: SAT sections, checked in is_resolved_test_score()
        decode(sprhold_hldd_code, '13','S11',   '62','S11', '14','S12', '15','S12', '63','S12', '16','S11', '64','S11', null) sat_code,
        
        -- cpt_code: max score retrieved by get_cpt_score(), score checked in Main
        decode(sprhold_hldd_code, '13','CPTE',  '62','CPTE','14','CPTM','15','CPTM','63','CPTM','16','CPTR','64','CPTR',null) cpt_code,
        
        -- new_cpt_code: max score retrieved by get_cpt_score(), score checked in Main
--        decode(sprhold_hldd_code, '13','CPTW','62','CPTW','14','NSM1','15','NSM1','63','NSM1','16','ANGR','64','ANGR',null) new_cpt_code,
        decode(sprhold_hldd_code, '13','CPTW','62','CPTW','14','NSM1','15','NSM1','63','NSM1',null) new_cpt_code,

        -- ang_code: max score retrieved by get_cpt_score(), score checked in Main - added 6/2019 moved 16/64 angr here
        decode(sprhold_hldd_code, '13','ANGW','62','ANGW','16','ANGR','64','ANGR',null) ang_code,
        
        -- course_code: checked in is_resolved_course(), is_resolved_course_read()
        decode(sprhold_hldd_code, '13','ENGL0123','62','ENGL0123','14','MATH0123','15','MATH0133','63','MATH0123','16','ENGL0113','64','ENGL0113',null) course_code,
        
        -- hold15_course2_code and hold15_course3_code both added for 1000 lvl classes to use parallel logic in existing code - added 6/2019
        decode(sprhold_hldd_code, '15','MATH1333',null) hold15_course2_code,
        decode(sprhold_hldd_code, '15','MATH1523',null) hold15_course3_code,
        
        sprhold_user
        
    FROM  spriden,
          sprhold
    WHERE 
         sprhold_hldd_code in ( '13','62','14','15','63','16','64','17','18' ) 
     AND (sprhold_to_date is null or sprhold_to_date > sysdate)
     AND sprhold_pidm = spriden_pidm
     AND spriden_change_ind is null order by sprhold_pidm, sprhold_hldd_code
   
    ;
    
    CURSOR c_sci IS --  Get people with current science holds
    SELECT
        spriden_id,
        spriden_first_name,
        spriden_last_name,
        sp1.sprhold_pidm,
        sp1.sprhold_hldd_code,
        sp1.rowid this_row,
        TO_CHAR(sp1.sprhold_from_date,'DD-MON-YYYY')hold_start,
        TO_CHAR(sp1.sprhold_to_date,'DD-MON-YYYY')hold_end,
        sp1.sprhold_user
    FROM
        spriden,
        sprhold sp1
    WHERE
    sp1.sprhold_hldd_code IN(
            '17',
            '18'
        )
        AND sp1.sprhold_pidm = spriden_pidm
        AND spriden_change_ind IS NULL
        AND(sp1.sprhold_to_date IS NULL
            OR sp1.sprhold_to_date > sysdate)
        AND sp1.sprhold_pidm NOT IN(
            SELECT
                actdef.sprhold_pidm
            FROM
                (
                    SELECT
                        sp2.sprhold_pidm,
                        COUNT(sp2.sprhold_pidm)cnt
                    FROM sprhold sp2
                    WHERE
                        sp2.sprhold_hldd_code IN(
                            '13',
                            '62',
                            '14',
                            '15',
                            '63',
                            '16',
                            '64'
                        )
                        AND(sp2.sprhold_to_date IS NULL
                            OR sp2.sprhold_to_date > SYSDATE)
                    GROUP BY
                        sp2.sprhold_pidm
                    HAVING
                        COUNT(sp2.sprhold_pidm)> 0
           )actdef
        );
    
/*************************************************
FUNCTION not used
*************************************************/    
    function csv_field(p_field varchar2) return varchar2 is
     t_field varchar2(500);
     begin
     t_field := p_field;
     t_field := replace(t_field,'"','""');
     return '"' || t_field || '"';
     end csv_field;
     
/*************************************************
FUNCTION is_resolved_ind
    Checks SORTEST to see if they've taken the test in p_resolved_code
*************************************************/
    FUNCTION is_resolved_ind( 
        p_pidm            VARCHAR2,
        p_resolved_code   VARCHAR2
    )RETURN VARCHAR2 IS
        return_resolved VARCHAR2(1)DEFAULT NULL;
    BEGIN
        SELECT
            'Y'
        INTO return_resolved
        FROM
            sortest
        WHERE
            sortest_pidm = p_pidm
            AND sortest_tesc_code = p_resolved_code;

        RETURN return_resolved;
    EXCEPTION
        WHEN no_data_found THEN
            return_resolved := '_';
            RETURN return_resolved;
    END is_resolved_ind;      
      
    --function is_resolved_act(p_pidm varchar2, p_resolved_code varchar2) return varchar2 is
    --  return_resolved varchar2(1) default null;
    --  begin
    --   select distinct 'Y' 
    --    into return_resolved
    --   from sortest
    --   where
    --            sortest_pidm = p_pidm
    --        and sortest_tesc_code = p_resolved_code
    --        and sortest_test_score >= 19
    --        and rownum = 1;
    --   
    --   return return_resolved;
    --   EXCEPTION 
    --      WHEN no_data_found THEN
    --         return_resolved := '_';
    --         return return_resolved;
    --  end is_resolved_act;  

/*************************************************
FUNCTION is_resolved_test_score
    Checks to see if they recieved a hard-coded score on ACT or SAT section
*************************************************/    
    FUNCTION is_resolved_test_score(
        p_pidm            VARCHAR2,
        p_resolved_code   VARCHAR2
    )RETURN VARCHAR2 IS
        return_resolved VARCHAR2(1)DEFAULT '_';
    BEGIN
        SELECT DISTINCT
            'Y'
        INTO return_resolved
        FROM
            sortest
        WHERE
            sortest_pidm = p_pidm
            AND sortest_tesc_code = p_resolved_code
            AND sortest_test_score >=
                CASE
                    WHEN p_resolved_code LIKE 'A__' THEN -- Mostly ACT codes
                        19
                    --WHEN p_resolved_code = 'S11' THEN 480 -- SAT Evid-Based Read and Write
                    WHEN p_resolved_code = 'S11' THEN 510 -- chg 6/14/2019 sw
                    --WHEN p_resolved_code = 'S12' THEN 530 -- SAT Math Section
                    WHEN p_resolved_code = 'S12' THEN 510 -- chg 6/14/2019 sw 
                END
            AND ROWNUM = 1;

        RETURN return_resolved;
    EXCEPTION
        WHEN no_data_found THEN
            return_resolved := '_';
            RETURN return_resolved;
    END is_resolved_test_score;
    
/*************************************************
FUNCTION get_cpt_score
    Return max CPT test score
*************************************************/     
    FUNCTION get_cpt_score(
        p_pidm            VARCHAR2,
        p_resolved_code   VARCHAR2
    )RETURN VARCHAR2 IS
        return_cpt_score NUMERIC DEFAULT 0;
    BEGIN
        SELECT
            MAX(sortest_test_score)
        INTO return_cpt_score
        FROM
            sortest
        WHERE
            sortest_pidm = p_pidm
            AND sortest_tesc_code = p_resolved_code;

        RETURN return_cpt_score;
    EXCEPTION
        WHEN no_data_found THEN
            return_cpt_score := 0;
            RETURN return_cpt_score;
    END get_cpt_score; 

/*************************************************
FUNCTION is_resolved_course
    Checks course (shrtckn) and grade (shrtckg) for substr(course_code)
      and (union) checks transfer credits (shrtrce) for equivalence 
*************************************************/    
    FUNCTION is_resolved_course(
        p_pidm        VARCHAR2,
        p_subj_code   VARCHAR2,
        p_crse_numb   VARCHAR2
    )RETURN VARCHAR2 IS
      return_resolved   VARCHAR2(1)DEFAULT NULL;
      
        v_crse_numb       VARCHAR2(100);
    BEGIN
        SELECT DISTINCT
            'Y'
        INTO return_resolved
        FROM
            (
                SELECT
                    shrtckn_pidm              pidm,
                    shrtckn_subj_code         subj,
                    shrtckn_crse_numb         crse,
                    shrtckg_grde_code_final   grade
                FROM
                    shrtckn, 
                       shrtckg
                WHERE
                    shrtckn_pidm = p_pidm
                    AND substr(shrtckn_crse_numb,1,1)IN(
                        '0',
                        '1'
                    )
                    AND shrtckn_pidm = shrtckg_pidm
                    AND shrtckn_term_code = shrtckg_term_code
                    AND shrtckn_seq_no = shrtckg_tckn_seq_no
                    AND substr(shrtckg_grde_code_final,1,1)IN (
                        'A',
                        'B',
                        'C',
                        'D',
                        'P'
                    ) 
                    AND substr(shrtckg_grde_code_final,1,2)<> 'AW'
                UNION
                SELECT
                    shrtrce_pidm        pidm,
                    shrtrce_subj_code   subj,
                    shrtrce_crse_numb   crse,
                    shrtrce_grde_code   grade
                FROM
                    shrtrce
                WHERE
                    shrtrce_pidm = p_pidm
                    AND substr(shrtrce_crse_numb,1,1)IN(
                        '0',
                        '1'
                    )
                    AND substr(shrtrce_grde_code,1,1)IN(
                        'A',
                        'B',
                        'C',
                        'D',
                        'P',
                        'S' --
                    )
                    AND substr(shrtrce_grde_code,1,2)<> 'AW'
            )d1
        WHERE
            d1.pidm = p_pidm
            AND d1.subj = p_subj_code
            AND(d1.crse = p_crse_numb
                OR d1.crse IN(
                '0133',
                '1113',
                '1213',
                '1473',
                '1513',
                '1000'
            ))
       --      and rownum = 1
            ;

        RETURN return_resolved;
    EXCEPTION
        WHEN no_data_found THEN
            return_resolved := '_';
            RETURN return_resolved;
    END is_resolved_course;

/*************************************************
FUNCTION is_resolved_course_read
    Checks course (shrtckn) and grade (shrtckg) for substr(course_code)
      and (union) checks transfer credits (shrtrce) for equivalence 
      Returns 'Y' or null
*************************************************/      
    FUNCTION is_resolved_course_read(
        p_pidm        VARCHAR2,
        p_subj_code   VARCHAR2,
        p_crse_numb   VARCHAR2
    )RETURN VARCHAR2 IS
      return_resolved   VARCHAR2(1)DEFAULT NULL;
      
        v_crse_numb       VARCHAR2(100);
    BEGIN
        SELECT DISTINCT
            'Y'
        INTO return_resolved
        FROM
            (
                SELECT
                    shrtckn_pidm              pidm,
                    shrtckn_subj_code         subj,
                    shrtckn_crse_numb         crse,
                    shrtckg_grde_code_final   grade
                FROM
                    shrtckn, 
                       shrtckg
                WHERE
                    shrtckn_pidm = p_pidm
                    AND substr(shrtckn_crse_numb,1,1)IN(
                        '0',
                        '1'
                    )
                    AND shrtckn_pidm = shrtckg_pidm
                    AND shrtckn_term_code = shrtckg_term_code
                    AND shrtckn_seq_no = shrtckg_tckn_seq_no
                    AND substr(shrtckg_grde_code_final,1,1)IN (
                        'A',
                        'B',
                        'C',
                        'D',
                        'P'
                    ) 
                       and substr(shrtckg_grde_code_final,1,2)<> 'AW'
                UNION
                SELECT
                    shrtrce_pidm        pidm,
                    shrtrce_subj_code   subj,
                    shrtrce_crse_numb   crse,
                    shrtrce_grde_code   grade
                FROM
                    shrtrce
                WHERE
                    shrtrce_pidm = p_pidm
                    AND substr(shrtrce_crse_numb,1,1)IN(
                        '0',
                        '1'
                    )
                    AND substr(shrtrce_grde_code,1,1)IN(
                        'A',
                        'B',
                        'C',
                        'D',
                        'P'
                    )
                    AND substr(shrtrce_grde_code,1,2)<> 'AW'
            )d1
        WHERE
            d1.pidm = p_pidm
            AND d1.subj = p_subj_code
            AND d1.crse = p_crse_numb 
       --      and rownum = 1
            ;

        RETURN return_resolved;
    EXCEPTION
        WHEN no_data_found THEN
            return_resolved := '_';
            RETURN return_resolved;
    END is_resolved_course_read;
     
/*************************************************
MAIN BLOCK
*************************************************/    
         
    BEGIN <<main_block>>
        dbms_output.put_line('Running Process');
        t_dat_file_def := utl_file.fopen(t_stu_dir,'FYEDEFS_test.dat','W');
    
        FOR r_def IN c_def LOOP -- for each row in deficiency cursor

            -- Check if this person has {subj} Deficiency Cleared code    
            lv_resolved_adm := null;
            lv_resolved_adm := is_resolved_ind(r_def.sprhold_pidm,r_def.resolve_code);
          
            -- Check if this person got a hard-coded ACT score, then SAT score
            lv_resolved_act := null; 
            lv_resolved_act := is_resolved_test_score(r_def.sprhold_pidm, r_def.act_code);
            IF lv_resolved_act = '_' THEN 
                lv_resolved_act := is_resolved_test_score(r_def.sprhold_pidm, r_def.sat_code);
            END IF;
            
            -- Get max(CPTx) test score
            lv_resolved_cpt := null;
            lv_cpt_score  := 0;
            lv_cpt_score := get_cpt_score(r_def.sprhold_pidm, r_def.cpt_code);
      
            -- Get max(new CPT) test score
            lv_new_cpt_score := 0;
            lv_new_cpt_score := get_cpt_score(r_def.sprhold_pidm, r_def.new_cpt_code);
            
            -- Get max(ANGx) test score
            lv_ang_score := 0;
            lv_ang_score := get_cpt_score(r_def.sprhold_pidm, r_def.ang_code);
      
            --Check if this person has taken remedial course here or transfer (course_code) and has passed
            lv_resolved_crse := null;
            IF r_def.sprhold_hldd_code NOT IN ('16','64') THEN
                -- chg 6/2019 - added if 15 then check any course code for passing grade in specified courses
                --lv_resolved_crse := is_resolved_course(r_def.sprhold_pidm, substr(r_def.course_code,1,4), substr(r_def.course_code,5,4));
                IF r_def.sprhold_hldd_code = '15' THEN
                    IF (is_resolved_course(r_def.sprhold_pidm, substr(r_def.course_code,1,4), substr(r_def.course_code,5,4)) = 'Y')
                        OR
                       (is_resolved_course(r_def.sprhold_pidm, substr(r_def.hold15_course2_code,1,4),substr(r_def.hold15_course2_code,5,4)) = 'Y')
                        OR
                       (is_resolved_course(r_def.sprhold_pidm, substr(r_def.hold15_course3_code,1,4),substr(r_def.hold15_course3_code,5,4)) = 'Y') 
                            THEN
                                lv_resolved_crse := 'Y';
                    END IF;
                ELSE 
                    lv_resolved_crse := is_resolved_course(r_def.sprhold_pidm, substr(r_def.course_code,1,4), substr(r_def.course_code,5,4));
                END IF;
            ELSE
                lv_resolved_crse := is_resolved_course_read(r_def.sprhold_pidm, substr(r_def.course_code,1,4), substr(r_def.course_code,5,4));
            END IF;
      
            -- Check CPT scores
            IF r_def.sprhold_hldd_code in ('14','63') THEN -- Math0123 Skills Def, Math Curr Def
                IF lv_cpt_score >= 44 or lv_new_cpt_score >= 60 THEN
                    lv_resolved_cpt := 'Y';
                ELSE
                    lv_resolved_cpt := '_';
                END IF;
            ELSIF r_def.sprhold_hldd_code = '15' THEN -- Math0133 Skills Def
                IF   lv_cpt_score >= 75 or lv_new_cpt_score >= 90 THEN
                    lv_resolved_cpt := 'Y';
                ELSE
                    lv_resolved_cpt := '_';
                END IF;
            ELSIF r_def.sprhold_hldd_code in ('13','62') THEN --Engl Skills Def, Engl Curr Def
                --IF lv_cpt_score > 79.4 OR lv_new_cpt_score >= 5 THEN -- sw : 6/2019 new score, new test 
                IF lv_cpt_score > 80 OR lv_new_cpt_score >= 5 OR lv_ang_score >= 255 THEN
                    lv_resolved_cpt := 'Y';
                ELSE
                    lv_resolved_cpt := '_';
                END IF;
        -- cg : 6/11/2018 : new cpt tests
        --    ELSIF lv_cpt_score > 74.4 THEN
            ELSIF r_def.sprhold_hldd_code in ('16','64') THEN --Read Skills Def, Read Curr Def
                --IF lv_cpt_score >= 75 or lv_new_cpt_score >= 251 THEN -- sw : 6/2019 moved ANGR to ang_code
                IF lv_cpt_score >= 75 or lv_ang_score >= 255 THEN
                    lv_resolved_cpt := 'Y';
                ELSE
                    lv_resolved_cpt := '_';
                END IF;
            ELSE
                lv_resolved_cpt := '_';
            END IF;
            
        --Set resolved flag
        lv_resolved := '_';
        IF lv_resolved_adm = 'Y' OR lv_resolved_act = 'Y' OR lv_resolved_cpt = 'Y' OR lv_resolved_crse = 'Y' THEN
            lv_resolved := 'Y';
        END IF;
  
        t_line_def := lv_resolved || '|'
                      || r_def.spriden_id || '|'
                      || r_def.spriden_first_name || '|'
                      || r_def.spriden_last_name || '|'
                      || r_def.sprhold_hldd_code || '|'
                      || r_def.hold_start || '|'
                      || r_def.hold_end || '|'
                      || r_def.sprhold_user || '|'
                      || r_def.resolve_code || '|'
                      || lv_resolved_adm || '|'
                      || r_def.act_code || '|'
                      || lv_resolved_act || '|'
                      || r_def.cpt_code || '|'
                      || lv_cpt_score || '|'
                      || lv_resolved_cpt || '|'
                      || r_def.course_code || '|'
                      || lv_resolved_crse || '|'
                      || '1';
        
        utl_file.put_line(t_dat_file_def,t_line_def,false);
      
        BEGIN << engl_math_read_update >>
            IF lv_resolved = 'Y' THEN
                UPDATE sprhold sprh
                    SET sprh.sprhold_to_date = SYSDATE - 1,
                    sprh.sprhold_reason = 'Deficiency Resolved',
                    sprh.sprhold_activity_date = SYSDATE
                WHERE
                    sprh.rowid = r_def.this_row;
    
            utl_file.put_line(t_dat_file_def,'Success:  ' ||t_line_def,false);
            END IF;
            
            EXCEPTION
                WHEN OTHERS then
                    utl_file.put_line(t_dat_file_def,'Error:  ' || t_line_def,false);
        END; -- engl_math_read_update
             
    END LOOP; --FOR r_def IN c_def
    
    BEGIN
        COMMIT;
    END;
     
    FOR r_sci IN c_sci LOOP -- process science defs
        t_line_def := 'Y' || '|'
                      || r_sci.spriden_id || '|'
                      || r_sci.spriden_first_name || '|'
                      || r_sci.spriden_last_name || '|'
                      || r_sci.sprhold_hldd_code || '|'
                      || r_sci.hold_start || '|'
                      || r_sci.hold_end || '|'
                      || r_sci.sprhold_user;
    
        utl_file.put_line(t_dat_file_def,t_line_def,false);
        BEGIN
            UPDATE sprhold sprh
            SET
                sprh.sprhold_to_date = SYSDATE - 1
                    ,
                sprh.sprhold_reason = 'Deficiency Resolved',
                sprh.sprhold_activity_date = SYSDATE
            WHERE
                sprh.rowid = r_sci.this_row;
    
            utl_file.put_line(t_dat_file_def,'Success:  ' || t_line_def,false);
        EXCEPTION
            WHEN OTHERS THEN
                utl_file.put_line(t_dat_file_def,'Error:  ' || t_line_def,false);
        END;
    
    END LOOP; --FOR r_sci IN c_sci
    
    BEGIN
        COMMIT;
    END;
    
    utl_file.fclose(t_dat_file_def);    

END NSU_FYE_DEFICIENCY;